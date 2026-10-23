import hashlib
import multiprocessing
import shutil
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


@app.task(name="facetrack.enroll", ignore_result=True)
def enroll(job, epoch):
    config.validate()
    stop, lost = threading.Event(), threading.Event()

    def heartbeat():
        last = time.monotonic()
        with httpx.Client(timeout=10, follow_redirects=False) as client:
            while not stop.wait(15):
                try:
                    api(client, "POST", f"/internal/v1/jobs/{job}/heartbeat", {"epoch": epoch})
                    last = time.monotonic()
                except httpx.HTTPStatusError as e:
                    if e.response.status_code in (401, 403, 404, 409):
                        lost.set()
                        return
                except httpx.HTTPError:
                    pass
                if time.monotonic() - last > 100:
                    lost.set()
                    return

    process = None
    with httpx.Client(timeout=20, follow_redirects=False) as client:
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
                    if count != data["byte_size"] or checksum.hexdigest() != data["source_sha256"]:
                        raise ValueError("Media integrity mismatch")
                context = multiprocessing.get_context("spawn")
                receive, send = context.Pipe(duplex=False)
                process = context.Process(
                    target=run_child,
                    args=(send, str(source), str(config.MANIFEST), str(config.PROFILE), data),
                )
                process.start()
                send.close()
                deadline = time.monotonic() + 300
                result = None
                while time.monotonic() < deadline and not lost.is_set():
                    if receive.poll(0.5):
                        result = receive.recv()
                        break
                    if not process.is_alive():
                        break
                if process.is_alive():
                    process.terminate()
                process.join(timeout=5)
                if process.is_alive():
                    process.kill()
                    process.join()
                receive.close()
                if lost.is_set():
                    return
                if result is None:
                    result = {"ok": False, "code": "PROCESS_TIMEOUT", "retryable": True}
                if result["ok"]:
                    payload = {"epoch": epoch, **result["result"]}
                    for attempt in range(3):
                        try:
                            api(client, "POST", f"/internal/v1/jobs/{job}/complete", payload)
                            return
                        except httpx.HTTPStatusError as e:
                            if e.response.status_code in (401, 403, 404, 409, 422):
                                return
                        except httpx.HTTPError:
                            pass
                        time.sleep(2**attempt)
                    # Lease reconciliation owns recovery if delivery remained unavailable.
                else:
                    api(
                        client,
                        "POST",
                        f"/internal/v1/jobs/{job}/fail",
                        {"epoch": epoch, "code": result["code"], "retryable": result["retryable"]},
                    )
        except httpx.HTTPStatusError as e:
            if e.response.status_code not in (401, 403, 404, 409):
                try:
                    api(
                        client,
                        "POST",
                        f"/internal/v1/jobs/{job}/fail",
                        {"epoch": epoch, "code": "DOWNLOAD_UNAVAILABLE", "retryable": True},
                    )
                except httpx.HTTPError:
                    pass
        except (httpx.HTTPError, ValueError, OSError, EOFError):
            try:
                api(
                    client,
                    "POST",
                    f"/internal/v1/jobs/{job}/fail",
                    {"epoch": epoch, "code": "WORKER_ERROR", "retryable": True},
                )
            except httpx.HTTPError:
                pass
        finally:
            stop.set()
            if process and process.is_alive():
                process.terminate()
                process.join(timeout=5)


def clean_abandoned():
    if not config.TEMP.exists() or config.TEMP.is_symlink():
        return
    for path in config.TEMP.glob("job-*"):
        if not path.is_symlink() and path.is_dir() and time.time() - path.stat().st_mtime > 600:
            shutil.rmtree(path)
