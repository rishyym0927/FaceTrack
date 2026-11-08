import hashlib
import multiprocessing
import os
import shutil
import signal
import tempfile
import threading
import time
from urllib.parse import urlparse

import httpx
from celery import Celery

from . import config
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


def post_fail(client, job, epoch, code, retryable):
    # A failed /fail is retried here, never followed by a second, different /fail.
    post_with_retry(
        client,
        f"/internal/v1/jobs/{job}/fail",
        {"epoch": epoch, "code": code, "retryable": retryable},
    )


def _child_entry(target, *args):
    # Own process group, so ffmpeg and any other grandchild die with the child.
    try:
        os.setpgid(0, 0)
    except (AttributeError, OSError):
        pass
    target(*args)


def start_child(target, args):
    context = multiprocessing.get_context("spawn")
    process = context.Process(target=_child_entry, args=(target, *args))
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


@app.task(name="facetrack.enroll", ignore_result=True)
def enroll(job, epoch):
    config.validate()
    stop, lost = threading.Event(), threading.Event()

    def heartbeat():
        last = time.monotonic()
        with http_client(10) as client:
            while not stop.wait(15):
                try:
                    api(client, "POST", f"/internal/v1/jobs/{job}/heartbeat", {"epoch": epoch})
                    last = time.monotonic()
                except httpx.HTTPStatusError as e:
                    if e.response.status_code in LEASE_LOST:
                        lost.set()
                        return
                except httpx.HTTPError:
                    pass
                if time.monotonic() - last > 100:
                    lost.set()
                    return

    process = None
    with http_client(20) as client:
        try:
            api(client, "POST", f"/internal/v1/jobs/{job}/start", {"epoch": epoch})
            thread = threading.Thread(target=heartbeat, daemon=True)
            thread.start()
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
                from pathlib import Path

                source = Path(tmp) / "input.video"
                if data.get("media_url"):
                    download_deadline = time.monotonic() + 120
                    count = 0
                    checksum = hashlib.sha256()
                    # Storage errors are about the signed URL, not this worker's API lease.
                    try:
                        with client.stream("GET", data["media_url"]) as response:
                            response.raise_for_status()
                            with source.open("xb") as stream:
                                source.chmod(0o600)
                                for block in response.iter_bytes(65536):
                                    count += len(block)
                                    if (
                                        count > 25 * 1024 * 1024
                                        or lost.is_set()
                                        or time.monotonic() > download_deadline
                                    ):
                                        raise ValueError("Invalid download")
                                    checksum.update(block)
                                    stream.write(block)
                    except httpx.HTTPStatusError as e:
                        if e.response.status_code < 500 and e.response.status_code not in (408, 429):
                            raise MediaUnavailable from e
                        raise StorageUnavailable from e
                    except httpx.HTTPError as e:
                        raise StorageUnavailable from e
                    if count != data["byte_size"] or checksum.hexdigest() != data["source_sha256"]:
                        raise ValueError("Media integrity mismatch")
                receive, send = multiprocessing.get_context("spawn").Pipe(duplex=False)
                process = start_child(
                    run_child, (send, str(source), str(config.MANIFEST), str(config.PROFILE), data)
                )
                send.close()
                deadline = time.monotonic() + 300
                result = None
                try:
                    while time.monotonic() < deadline and not lost.is_set():
                        if receive.poll(0.5):
                            result = receive.recv()
                            break
                        if not process.is_alive():
                            break
                finally:
                    # Before the temporary directory is removed.
                    stop_child(process)
                    receive.close()
                if lost.is_set():
                    return
                if result is None:
                    result = {"ok": False, "code": "PROCESS_TIMEOUT", "retryable": True}
                if result["ok"]:
                    payload = {"epoch": epoch, **result["result"]}
                    status = post_with_retry(client, f"/internal/v1/jobs/{job}/complete", payload)
                    if status == 422:
                        post_fail(client, job, epoch, "RESULT_REJECTED", False)
                    # Lease loss ends here; lease reconciliation owns an unavailable API.
                else:
                    post_fail(client, job, epoch, result["code"], result["retryable"])
        except MediaUnavailable:
            post_fail(client, job, epoch, "MEDIA_UNAVAILABLE", False)
        except StorageUnavailable:
            post_fail(client, job, epoch, "DOWNLOAD_UNAVAILABLE", True)
        except httpx.HTTPStatusError as e:
            if e.response.status_code not in LEASE_LOST:
                post_fail(client, job, epoch, "DOWNLOAD_UNAVAILABLE", True)
        except (httpx.HTTPError, ValueError, OSError, EOFError):
            post_fail(client, job, epoch, "WORKER_ERROR", True)
        finally:
            stop.set()
            if process is not None and process.exitcode is None:
                stop_child(process)


def clean_abandoned():
    if not config.TEMP.exists() or config.TEMP.is_symlink():
        return
    for path in config.TEMP.glob("job-*"):
        if not path.is_symlink() and path.is_dir() and time.time() - path.stat().st_mtime > 600:
            shutil.rmtree(path)
