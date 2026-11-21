import hashlib
import multiprocessing
import os
import shutil
import signal
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.parse import urlparse

import httpx
from celery import Celery

from . import config, log
from .childproc import child_entry
from .inference import run_child

app = Celery("facetrack-enrollment", broker=config.REDIS)
app.conf.update(
    task_serializer="json",
    accept_content=["json"],
    result_serializer="json",
    task_ignore_result=True,
    task_acks_late=True,
    worker_prefetch_multiplier=1,
    broker_transport_options={"visibility_timeout": 900},
    task_default_queue="enrollment",
    worker_hijack_root_logger=False,
)


def api(client, method, path, body=None):
    response = client.request(
        method, config.API + path, json=body, headers={"Authorization": "Bearer " + config.TOKEN}
    )
    response.raise_for_status()
    return response


def http_client(timeout):
    return httpx.Client(timeout=timeout, follow_redirects=False)


LEASE_LOST = (401, 403, 404, 409)
TERMINAL_CONFLICTS = ("JOB_INPUT_REVOKED", "INPUT_CHANGED", "RESULT_CONFLICT")


def conflict_code(error):
    """API error code of a 409 response, or None."""
    if error.response.status_code != 409:
        return None
    try:
        return error.response.json()["error"]["code"]
    except (ValueError, KeyError, TypeError):
        return None


class MediaUnavailable(Exception):
    """The signed media URL is permanently unusable (expired, revoked or deleted object)."""


class StorageUnavailable(Exception):
    """Storage returned 5xx or could not be reached; a later attempt may succeed."""


def post_with_retry(client, path, body, attempts=3):
    """POST, retrying transport errors and 5xx with backoff. Returns None on success, the
    final 4xx status code, or 0 when the API stayed unavailable. Never raises httpx errors."""
    for attempt in range(attempts):
        try:
            api(client, "POST", path, body)
            return None
        except httpx.HTTPStatusError as e:
            if e.response.status_code < 500:
                return e.response.status_code
        except httpx.HTTPError:
            pass
        if attempt + 1 < attempts:
            time.sleep(2**attempt)
    return 0


def post_fail(client, job, epoch, code, retryable, stage=None):
    # A failed /fail is retried here, never followed by a second, different /fail.
    log.event("job_failed", "warning", job_id=job, code=code, retryable=retryable, stage=stage)
    post_with_retry(
        client,
        f"/internal/v1/jobs/{job}/fail",
        {"epoch": epoch, "code": code, "retryable": retryable},
    )


def start_child(target, args):
    context = multiprocessing.get_context("spawn")
    process = context.Process(target=child_entry, args=(os.getpid(), target, *args))
    process.start()
    try:
        os.setpgid(process.pid, process.pid)  # Both sides set it, so there is no race.
    except (AttributeError, OSError):
        pass
    return process


def _signal_group(process, sig, fallback):
    if hasattr(os, "killpg"):
        try:
            os.killpg(process.pid, sig)
            return
        except (ProcessLookupError, PermissionError):
            pass
    if process.is_alive():
        fallback()


def stop_child(process):
    """Terminate, kill and join the child's whole process group."""
    if process is None or process.pid is None:
        return
    if hasattr(signal, "SIGKILL"):
        _signal_group(process, signal.SIGTERM, process.terminate)
        process.join(timeout=5)
        _signal_group(process, signal.SIGKILL, process.kill)
    else:
        process.terminate()
        process.join(timeout=5)
        if process.is_alive():
            process.kill()
    process.join()


class LeaseLost(Exception):
    """The API no longer lets this worker finish the job; whoever holds it now owns the result."""


class Heartbeat(threading.Thread):
    """Renews the job lease and carries the step the teacher's screen shows.

    The lease is 120 s and is renewed every ``interval`` seconds, earlier when the step changes
    (updates are spaced at least ``spacing`` seconds apart). ``lost`` is set when the API rejects
    the lease or stays silent for ``silent_after`` seconds. ``end()`` wakes the thread at once
    instead of leaving it asleep for the rest of its interval.
    """

    def __init__(self, job, epoch, interval=15, spacing=2, silent_after=100):
        super().__init__(daemon=True, name=f"heartbeat-{job}")
        self.job, self.epoch = job, epoch
        self.interval, self.spacing, self.silent_after = interval, spacing, silent_after
        self.stopped, self.lost, self.changed = (threading.Event() for _ in range(3))
        # The result is being committed: a late heartbeat 409 is expected, not a lost lease.
        self.closing = threading.Event()
        self._step = None  # (name, percent), replaced as one object so a reader never sees half

    def show(self, name, percent=None):
        """Tell the API which step this job is on; sent with the next heartbeat."""
        self._step = (name, percent)
        self.changed.set()

    def end(self):
        self.stopped.set()
        self.changed.set()

    def run(self):
        last = time.monotonic()
        with http_client(10) as client:
            while not self.stopped.is_set():
                self.changed.wait(self.interval)
                if self.stopped.is_set():
                    break
                body, step = {"epoch": self.epoch}, None
                if self.changed.is_set():
                    # Cleared before the step is read: a show() after this point sets it again,
                    # so the newest step is never lost between the read and the clear.
                    self.changed.clear()
                    step = self._step
                if step:
                    body["stage"] = step[0]
                    if step[1] is not None:
                        body["percent"] = int(step[1])
                try:
                    api(client, "POST", f"/internal/v1/jobs/{self.job}/heartbeat", body)
                    last = time.monotonic()
                except httpx.HTTPStatusError as e:
                    if e.response.status_code in LEASE_LOST:
                        if self.closing.is_set():
                            return  # the job finished while this heartbeat was in flight
                        log.event("lease_lost", "warning", job_id=self.job,
                                  reason="heartbeat_rejected", status=e.response.status_code)
                        self.lost.set()
                        return
                    if step:
                        self.changed.set()  # not delivered: send the step again
                except httpx.HTTPError:
                    if step:
                        self.changed.set()
                if time.monotonic() - last > self.silent_after:
                    log.event("lease_lost", "warning", job_id=self.job, reason="heartbeat_silent")
                    self.lost.set()
                    return
                self.stopped.wait(self.spacing)


MIN_PART_BYTES = 2 * 1024 * 1024


class RangeUnsupported(Exception):
    """The storage server answered a ranged request with the whole file or something unusable."""


def download_parts():
    """DOWNLOAD_PARTS (default 4, 1 = one stream as before, at most 8): connections per download."""
    try:
        return min(8, max(1, int(os.environ.get("DOWNLOAD_PARTS", "4"))))
    except ValueError:
        return 4


def fetch_media(client, url, destination, byte_size, sha256, lost):
    """Download the signed URL to ``destination`` and verify size and SHA-256. Returns the bytes.

    Storage is 125 ms away, and one TCP stream over such a link fills slowly (a 11 MB segment took
    2-14 s). A large file is fetched as several ranges at once. The file is checked against the
    leased size and SHA-256 exactly as before; a server that ignores ranges is read in one stream.
    """
    parts = min(download_parts(), byte_size // MIN_PART_BYTES)
    if parts >= 2:
        try:
            return fetch_parts(client, url, destination, byte_size, sha256, lost, parts)
        except RangeUnsupported:
            log.event("download_ranges_unsupported", "warning")
            destination.unlink(missing_ok=True)
    return fetch_single(client, url, destination, byte_size, sha256, lost)


def fetch_parts(client, url, destination, byte_size, sha256, lost, parts):
    size = -(-byte_size // parts)
    spans = [(i * size, min(byte_size, (i + 1) * size) - 1) for i in range(parts) if i * size < byte_size]
    deadline = time.monotonic() + 120
    with destination.open("xb") as stream:
        destination.chmod(0o600)
        stream.truncate(byte_size)

    def get(span):
        start, end = span
        for attempt in (1, 2):
            try:
                with client.stream("GET", url, headers={"Range": f"bytes={start}-{end}"}) as response:
                    if response.status_code == 200:
                        raise RangeUnsupported
                    response.raise_for_status()
                    if response.status_code != 206 or not response.headers.get(
                        "content-range", ""
                    ).startswith(f"bytes {start}-{end}/"):
                        raise RangeUnsupported
                    position = start
                    with destination.open("r+b") as out:
                        out.seek(start)
                        for block in response.iter_bytes(65536):
                            if lost.is_set():
                                raise LeaseLost
                            if time.monotonic() > deadline or position + len(block) > end + 1:
                                raise ValueError("Invalid download")
                            out.write(block)
                            position += len(block)
                    if position != end + 1:
                        raise ValueError("Media integrity mismatch")
                    return
            except httpx.HTTPStatusError as e:
                if attempt == 2 or not (e.response.status_code >= 500 or e.response.status_code in (408, 429)):
                    raise
            except httpx.TransportError:
                if attempt == 2:
                    raise

    pool = ThreadPoolExecutor(len(spans), thread_name_prefix="download")
    try:
        try:
            for future in [pool.submit(get, span) for span in spans]:
                future.result()
        finally:
            pool.shutdown(wait=True, cancel_futures=True)
    except httpx.HTTPStatusError as e:
        if e.response.status_code < 500 and e.response.status_code not in (408, 429):
            raise MediaUnavailable from e
        raise StorageUnavailable from e
    except httpx.HTTPError as e:
        raise StorageUnavailable from e
    checksum = hashlib.sha256()
    with destination.open("rb") as stream:
        while block := stream.read(1024 * 1024):
            checksum.update(block)
    if destination.stat().st_size != byte_size or checksum.hexdigest() != sha256:
        raise ValueError("Media integrity mismatch")
    return byte_size


def fetch_single(client, url, destination, byte_size, sha256, lost):
    """Stream the signed URL into ``destination``, hashing as it arrives. Returns the byte count.

    Storage errors are about the signed URL, not this worker's API lease.
    """
    count = 0
    checksum = hashlib.sha256()
    deadline = time.monotonic() + 120
    try:
        with client.stream("GET", url) as response:
            response.raise_for_status()
            with destination.open("xb") as stream:
                destination.chmod(0o600)
                for block in response.iter_bytes(65536):
                    count += len(block)
                    if lost.is_set():
                        raise LeaseLost
                    if count > 25 * 1024 * 1024 or time.monotonic() > deadline:
                        raise ValueError("Invalid download")
                    checksum.update(block)
                    stream.write(block)
    except httpx.HTTPStatusError as e:
        if e.response.status_code < 500 and e.response.status_code not in (408, 429):
            raise MediaUnavailable from e
        raise StorageUnavailable from e
    except httpx.HTTPError as e:
        raise StorageUnavailable from e
    if count != byte_size or checksum.hexdigest() != sha256:
        raise ValueError("Media integrity mismatch")
    return count


def spawn_inference(source, data, wait):
    """Start the job's child. With ``wait`` it loads the models now and idles until it is sent
    ("go",), so loading overlaps the download. Returns (process, parent end of the pipe)."""
    parent, child = multiprocessing.get_context("spawn").Pipe(duplex=True)
    process = start_child(
        run_child, (child, str(source), str(config.MANIFEST), str(config.PROFILE), data, wait)
    )
    child.close()
    return process, parent


@app.task(name="facetrack.enroll", ignore_result=True)
def enroll(job, epoch):
    config.validate()
    beat = Heartbeat(job, epoch)
    started = time.monotonic()
    stage = "start"
    log.event("job_start", job_id=job, epoch=epoch)
    process = connection = None
    with http_client(20) as client:
        try:
            api(client, "POST", f"/internal/v1/jobs/{job}/start", {"epoch": epoch})
            beat.start()
            stage = "input"
            data = api(client, "GET", f"/internal/v1/jobs/{job}/input?epoch={epoch}").json()
            if data.get("kind") == "delivery":
                api(client, "POST", f"/internal/v1/jobs/{job}/deliver", {"epoch": epoch})
                return
            if data.get("media_url") and (
                urlparse(data["media_url"]).scheme != "https"
                or urlparse(data["media_url"]).netloc != urlparse(config.MEDIA_ORIGIN).netloc
            ):
                raise ValueError("Unexpected media origin")
            if config.TEMP.is_symlink():
                raise ValueError("Unsafe temporary root")
            config.TEMP.mkdir(parents=True, exist_ok=True, mode=0o700)
            config.TEMP.chmod(0o700)
            with tempfile.TemporaryDirectory(prefix="job-", dir=config.TEMP) as tmp:
                source = Path(tmp) / "input.video"
                beat.show("preparing")
                # Only model jobs: reports and timetables never load a model.
                if data.get("media_url") and data.get("kind") not in ("report", "timetable"):
                    stage = "inference"
                    process, connection = spawn_inference(source, data, wait=True)
                if data.get("media_url"):
                    stage = "download"
                    download_started = time.monotonic()
                    count = fetch_media(
                        client, data["media_url"], source, data["byte_size"],
                        data["source_sha256"], beat.lost,
                    )
                    spent = log.elapsed_ms(download_started)
                    log.event("download_done", job_id=job, bytes=count, duration_ms=spent,
                              parts=min(download_parts(), count // MIN_PART_BYTES) or 1,
                              mbps=round(count * 8 / 1000 / max(spent, 1), 1))
                stage = "inference"
                inference_started = time.monotonic()
                if process is None:
                    process, connection = spawn_inference(source, data, wait=False)
                else:
                    try:
                        connection.send(("go",))
                    except (OSError, ValueError):
                        pass  # the child already ended; its message, if any, is read below
                deadline = time.monotonic() + 300
                result = None
                try:
                    while time.monotonic() < deadline and not beat.lost.is_set():
                        if connection.poll(0.5):
                            message = connection.recv()
                            if "progress" in message:  # a step update, not the result yet
                                beat.show(message["progress"]["stage"],
                                          message["progress"].get("percent"))
                                continue
                            result = message
                            break
                        if not process.is_alive():
                            break
                finally:
                    # Before the temporary directory is removed.
                    stop_child(process)
                    connection.close()
                if beat.lost.is_set():
                    return
                if result is None:
                    result = {"ok": False, "code": "PROCESS_TIMEOUT", "retryable": True}
                    log.event("inference_timeout", "warning", job_id=job,
                              exitcode=process.exitcode,
                              duration_ms=log.elapsed_ms(inference_started))
                if result["ok"]:
                    stage = "complete"
                    found = result["result"]
                    log.event(
                        "inference_done",
                        job_id=job,
                        kind=data.get("kind"),
                        inference_ms=log.elapsed_ms(inference_started),
                        timings=found.get("timings"),
                        quality=found.get("quality"),
                        reject_reasons=found.get("reject_reasons"),
                        face_px_median=found.get("face_px_median"),
                        sample_fps=found.get("sample_fps"),
                        proposals=len(found.get("proposals", [])) if "proposals" in found else None,
                        unknown_observations=found.get("unknown_observations"),
                    )
                    beat.show("finalizing")
                    beat.closing.set()
                    payload = {"epoch": epoch, **found}
                    status = post_with_retry(client, f"/internal/v1/jobs/{job}/complete", payload)
                    if status == 422:
                        post_fail(client, job, epoch, "RESULT_REJECTED", False, stage)
                    elif status is not None:
                        log.event("complete_not_accepted", "warning", job_id=job, status=status)
                    else:
                        log.event("job_done", job_id=job, total_ms=log.elapsed_ms(started))
                    # Lease loss ends here; lease reconciliation owns an unavailable API.
                else:
                    post_fail(client, job, epoch, result["code"], result["retryable"], "inference")
        except LeaseLost:
            pass  # already logged by the heartbeat; the new holder owns the job
        except MediaUnavailable:
            post_fail(client, job, epoch, "MEDIA_UNAVAILABLE", False, stage)
        except StorageUnavailable:
            post_fail(client, job, epoch, "DOWNLOAD_UNAVAILABLE", True, stage)
        except httpx.HTTPStatusError as e:
            code = conflict_code(e)
            if code in TERMINAL_CONFLICTS:
                # The input is gone or changed: release the lease now instead of blocking
                # finalisation until it expires.
                post_fail(client, job, epoch, code, False, stage)
            elif e.response.status_code not in LEASE_LOST:
                post_fail(client, job, epoch, "DOWNLOAD_UNAVAILABLE", True, stage)
            else:
                log.event("lease_lost", "warning", job_id=job, reason="api_rejected",
                          status=e.response.status_code, stage=stage)
        except Exception as e:
            # Any other failure (a malformed API body, a failed spawn, a bug) must still release
            # the lease: without this the job sat until its lease expired, two minutes later.
            # The exception class and the stage say what went wrong; its text can hold paths.
            log.event("worker_error", "error", job_id=job, stage=stage, error=type(e).__name__)
            post_fail(client, job, epoch, "WORKER_ERROR", True, stage)
        finally:
            beat.end()
            if process is not None and process.exitcode is None:
                stop_child(process)
            if connection is not None:
                connection.close()
            if beat.is_alive():
                beat.join(timeout=2)


def clean_abandoned():
    if not config.TEMP.exists() or config.TEMP.is_symlink():
        return
    for path in config.TEMP.glob("job-*"):
        try:
            if not path.is_symlink() and path.is_dir() and time.time() - path.stat().st_mtime > 600:
                shutil.rmtree(path)
        except OSError:
            continue  # one undeletable directory must not keep the rest from being cleaned
