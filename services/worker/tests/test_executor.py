"""Job executor failure paths against a mocked API and Storage (no Redis, no models)."""

import json
import os
import subprocess
import time

import httpx
import pytest

from facetrack_worker import config, executor

JOB = "00000000-0000-0000-0000-000000000001"
MEDIA = "https://storage.test/object/sign/capture.mp4"


def ok_child(pipe, *args):
    pipe.send({"ok": True, "result": {"kind": "report", "csv_base64": "", "pdf_base64": ""}})
    pipe.close()


def grandchild_child(pipe, *args):
    sleeper = subprocess.Popen(["sleep", "60"])
    pipe.send(sleeper.pid)
    time.sleep(60)


class FakeApi:
    """Routes job calls; `responses` maps a path suffix to a list of status codes to return."""

    def __init__(self, job_input, responses=None):
        self.job_input = job_input
        self.responses = responses or {}
        self.calls = []

    def __call__(self, request):
        path = request.url.path
        body = json.loads(request.content) if request.content else None
        self.calls.append((request.method, path, body))
        if request.url.host == "storage.test":
            return httpx.Response(self.responses.get("media", [200])[0], content=b"")
        suffix = path.rsplit("/", 1)[-1]
        queued = self.responses.get(suffix)
        if queued:
            return httpx.Response(queued.pop(0) if len(queued) > 1 else queued[0], json={})
        if suffix == "input":
            return httpx.Response(200, json=self.job_input)
        return httpx.Response(200, json={})

    def fails(self):
        return [body for _, path, body in self.calls if path.endswith("/fail")]


@pytest.fixture
def mocked(monkeypatch, tmp_path):
    def install(job_input, responses=None):
        fake = FakeApi(job_input, responses)
        transport = httpx.MockTransport(fake)
        monkeypatch.setattr(
            executor,
            "http_client",
            lambda timeout: httpx.Client(transport=transport, follow_redirects=False),
        )
        monkeypatch.setattr(config, "validate", lambda: None)
        monkeypatch.setattr(config, "API", "http://api.test")
        monkeypatch.setattr(config, "MEDIA_ORIGIN", "https://storage.test")
        monkeypatch.setattr(config, "TEMP", tmp_path / "tmp")
        monkeypatch.setattr(executor.time, "sleep", lambda seconds: None)
        return fake

    return install


@pytest.mark.parametrize("status", [403, 404])
def test_storage_rejection_is_a_permanent_media_failure(mocked, status):
    fake = mocked({"media_url": MEDIA, "byte_size": 1, "source_sha256": "x"}, {"media": [status]})
    executor.enroll(JOB, 1)
    assert fake.fails() == [{"epoch": 1, "code": "MEDIA_UNAVAILABLE", "retryable": False}]


@pytest.mark.parametrize("status", [408, 429, 503])
def test_storage_outage_stays_retryable(mocked, status):
    fake = mocked({"media_url": MEDIA, "byte_size": 1, "source_sha256": "x"}, {"media": [status]})
    executor.enroll(JOB, 1)
    assert fake.fails() == [{"epoch": 1, "code": "DOWNLOAD_UNAVAILABLE", "retryable": True}]


def test_failed_fail_call_is_retried_not_replaced(mocked):
    fake = mocked(
        {"media_url": MEDIA, "byte_size": 1, "source_sha256": "x"},
        {"media": [404], "fail": [503, 503, 200]},
    )
    executor.enroll(JOB, 1)
    assert fake.fails() == [{"epoch": 1, "code": "MEDIA_UNAVAILABLE", "retryable": False}] * 3


def test_rejected_result_posts_non_retryable_failure(mocked, monkeypatch):
    monkeypatch.setattr(executor, "run_child", ok_child)
    fake = mocked({"kind": "report", "snapshot": {}}, {"complete": [422]})
    executor.enroll(JOB, 1)
    assert [p for _, p, _ in fake.calls if p.endswith("/complete")]
    assert fake.fails() == [{"epoch": 1, "code": "RESULT_REJECTED", "retryable": False}]


def test_lost_lease_on_complete_posts_nothing(mocked, monkeypatch):
    monkeypatch.setattr(executor, "run_child", ok_child)
    fake = mocked({"kind": "report", "snapshot": {}}, {"complete": [409]})
    executor.enroll(JOB, 1)
    assert fake.fails() == []


def test_post_with_retry_reports_outcome(monkeypatch):
    monkeypatch.setattr(executor.time, "sleep", lambda seconds: None)
    monkeypatch.setattr(config, "API", "http://api.test")
    for codes, expected, calls in (([200], None, 1), ([422], 422, 1), ([500], 0, 3)):
        seen = []

        def handler(request, codes=codes, seen=seen):
            seen.append(request)
            return httpx.Response(codes[0])

        with httpx.Client(transport=httpx.MockTransport(handler)) as client:
            assert executor.post_with_retry(client, "/x", {}) == expected
        assert len(seen) == calls


@pytest.mark.skipif(not hasattr(os, "killpg"), reason="POSIX process groups")
def test_stop_child_kills_the_whole_process_group():
    import multiprocessing

    receive, send = multiprocessing.get_context("spawn").Pipe(duplex=False)
    process = executor.start_child(grandchild_child, (send,))
    send.close()
    assert receive.poll(30)
    grandchild = receive.recv()
    assert os.getpgid(process.pid) == process.pid
    executor.stop_child(process)
    assert not process.is_alive()
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        try:
            os.kill(grandchild, 0)
        except ProcessLookupError:
            break
        time.sleep(0.1)
    else:
        pytest.fail("grandchild survived its process group")


def test_conflict_code_reads_api_error_envelope():
    import httpx

    from facetrack_worker import executor

    def err(status, body):
        request = httpx.Request("POST", "https://x/y")
        return httpx.HTTPStatusError("e", request=request, response=httpx.Response(status, json=body, request=request))

    assert executor.conflict_code(err(409, {"error": {"code": "JOB_INPUT_REVOKED"}})) == "JOB_INPUT_REVOKED"
    assert executor.conflict_code(err(409, {"error": {"code": "STALE_LEASE"}})) == "STALE_LEASE"
    assert executor.conflict_code(err(500, {"error": {"code": "JOB_INPUT_REVOKED"}})) is None
    assert executor.conflict_code(err(409, {"oops": 1})) is None
    assert "STALE_LEASE" not in executor.TERMINAL_CONFLICTS


# ---- audit regressions -------------------------------------------------------------------


def heartbeat_threads():
    import threading

    return [t for t in threading.enumerate() if t.name.startswith("heartbeat-") and t.is_alive()]


def test_heartbeat_thread_is_gone_when_the_job_returns(mocked, monkeypatch):
    # It used to sleep out the rest of its 15 s interval after every job.
    monkeypatch.setattr(executor, "run_child", ok_child)
    mocked({"kind": "report", "snapshot": {}})
    executor.enroll(JOB, 1)
    assert heartbeat_threads() == []


def test_unexpected_exception_still_releases_the_lease(mocked):
    # A malformed input body (no byte_size) is a KeyError, not an httpx/OSError/ValueError. It
    # used to escape and leave the job leased until it expired two minutes later.
    fake = mocked({"media_url": MEDIA, "source_sha256": "x"})
    executor.enroll(JOB, 1)
    assert fake.fails() == [{"epoch": 1, "code": "WORKER_ERROR", "retryable": True}]


def test_heartbeat_resends_a_step_the_api_did_not_receive(monkeypatch):
    seen = []

    def handler(request):
        seen.append(json.loads(request.content))
        return httpx.Response(500 if len(seen) == 1 else 200, json={})

    beat = executor.Heartbeat(JOB, 1, interval=0.05, spacing=0.01)
    monkeypatch.setattr(
        executor, "http_client", lambda timeout: httpx.Client(transport=httpx.MockTransport(handler))
    )
    monkeypatch.setattr(config, "API", "http://api.test")
    try:
        beat.show("recognizing", 40)
        beat.start()
        deadline = time.monotonic() + 5
        while len(seen) < 2 and time.monotonic() < deadline:
            time.sleep(0.01)
    finally:
        beat.end()
        beat.join(timeout=5)
    assert seen[0]["stage"] == seen[1]["stage"] == "recognizing" and seen[1]["percent"] == 40


def test_heartbeat_end_wakes_it_immediately(monkeypatch):
    beat = executor.Heartbeat(JOB, 1, interval=60)
    monkeypatch.setattr(
        executor,
        "http_client",
        lambda timeout: httpx.Client(
            transport=httpx.MockTransport(lambda r: httpx.Response(200, json={}))
        ),
    )
    beat.start()
    started = time.monotonic()
    beat.end()
    beat.join(timeout=5)
    assert not beat.is_alive() and time.monotonic() - started < 2


def test_lease_lost_during_download_is_not_reported_as_a_worker_error(tmp_path):
    import threading

    lost = threading.Event()
    lost.set()
    transport = httpx.MockTransport(lambda r: httpx.Response(200, content=b"x" * 10))
    with httpx.Client(transport=transport) as client:
        with pytest.raises(executor.LeaseLost):
            executor.fetch_media(client, MEDIA, tmp_path / "in", 10, "0" * 64, lost)


def test_model_child_is_started_before_the_download_and_told_when_media_is_ready(
    mocked, monkeypatch
):
    import hashlib

    body = b"video-bytes"
    started = []
    real_start = executor.start_child

    def recording_start(target, args):
        started.append((time.monotonic(), args[-1]))  # the `wait` flag
        return real_start(target, args)

    monkeypatch.setattr(executor, "start_child", recording_start)
    monkeypatch.setattr(executor, "run_child", go_child)
    fake = mocked(
        {"media_url": MEDIA, "byte_size": len(body), "source_sha256": hashlib.sha256(body).hexdigest()}
    )
    transport = httpx.MockTransport(
        lambda r: httpx.Response(200, content=body) if r.url.host == "storage.test" else fake(r)
    )
    monkeypatch.setattr(
        executor, "http_client", lambda t: httpx.Client(transport=transport, follow_redirects=False)
    )
    executor.enroll(JOB, 1)
    assert [wait for _, wait in started] == [True]  # spawned once, in wait-for-media mode
    complete = [b for _, p, b in fake.calls if p.endswith("/complete")]
    assert complete and complete[0]["size_seen"] == len(body)  # the file was there on "go"


def go_child(pipe, source, manifest, profile, expected, wait):
    from pathlib import Path

    assert wait is True
    assert pipe.recv() == ("go",)
    pipe.send({"ok": True, "result": {"size_seen": Path(source).stat().st_size}})
    pipe.close()


def waiting_child(pipe, *args):
    pipe.recv()
    time.sleep(60)


def test_preloaded_child_is_stopped_when_the_download_fails(mocked, monkeypatch):
    started = []
    real_start = executor.start_child

    def recording_start(target, args):
        process = real_start(target, args)
        started.append(process)
        return process

    monkeypatch.setattr(executor, "start_child", recording_start)
    monkeypatch.setattr(executor, "run_child", waiting_child)
    fake = mocked({"media_url": MEDIA, "byte_size": 1, "source_sha256": "x"}, {"media": [404]})
    executor.enroll(JOB, 1)
    assert fake.fails()[0]["code"] == "MEDIA_UNAVAILABLE"
    assert len(started) == 1 and not started[0].is_alive()


def test_report_jobs_do_not_preload_a_model_child(mocked, monkeypatch):
    waits = []
    real_start = executor.start_child
    monkeypatch.setattr(
        executor, "start_child", lambda t, a: waits.append(a[-1]) or real_start(t, a)
    )
    monkeypatch.setattr(executor, "run_child", ok_child)
    mocked({"kind": "report", "snapshot": {}})
    executor.enroll(JOB, 1)
    assert waits == [False]


def test_cleanup_continues_past_a_directory_it_cannot_remove(tmp_path, monkeypatch):
    import shutil

    monkeypatch.setattr(config, "TEMP", tmp_path)
    old = time.time() - 3600
    for name in ("job-a", "job-b"):
        (tmp_path / name).mkdir()
        os.utime(tmp_path / name, (old, old))
    real = shutil.rmtree
    calls = []

    def flaky(path, *args, **kwargs):
        calls.append(path.name)
        if path.name == min(("job-a", "job-b")):
            raise PermissionError
        return real(path, *args, **kwargs)

    monkeypatch.setattr(executor.shutil, "rmtree", flaky)
    executor.clean_abandoned()
    assert sorted(calls) == ["job-a", "job-b"]


def test_child_bootstrap_is_light_and_exits_when_its_parent_dies():
    code = (
        "import os, sys, time\n"
        "from facetrack_worker import childproc\n"
        "assert 'celery' not in sys.modules and 'httpx' not in sys.modules\n"
        "childproc.watch_parent(os.getpid() + 100000, interval=0.05, exit_code=7)\n"
        "time.sleep(10)\n"
    )
    started = time.monotonic()
    result = subprocess.run([__import__("sys").executable, "-c", code], timeout=20)
    assert result.returncode == 7 and time.monotonic() - started < 8


def test_report_child_does_not_import_the_vision_stack():
    code = (
        "import sys\n"
        "import facetrack_worker.inference\n"
        "assert 'cv2' not in sys.modules and 'onnxruntime' not in sys.modules, 'heavy import'\n"
    )
    subprocess.run([__import__("sys").executable, "-c", code], check=True, timeout=30)


# ---- parallel ranged download ---------------------------------------------------------------

import hashlib as _hashlib
import threading
import os as _os


def _range_server(body, *, ignore_ranges=False, fail=None, seen=None):
    """A storage double: honours Range (206 + Content-Range) unless told not to."""

    def handler(request):
        header = request.headers.get("range")
        if seen is not None:
            seen.append(header)
        code = fail(request) if fail else None
        if code:
            return httpx.Response(code)
        if header is None or ignore_ranges:
            return httpx.Response(200, content=body)
        start, end = (int(x) for x in header.removeprefix("bytes=").split("-"))
        return httpx.Response(
            206,
            content=body[start : end + 1],
            headers={"content-range": f"bytes {start}-{end}/{len(body)}"},
        )

    return httpx.MockTransport(handler)


BODY = _os.urandom(9 * 1024 * 1024 + 123)
DIGEST = _hashlib.sha256(BODY).hexdigest()


def _fetch(tmp_path, transport, **kw):
    with httpx.Client(transport=transport) as client:
        return executor.fetch_media(
            client, MEDIA, tmp_path / "in", kw.get("size", len(BODY)), kw.get("sha", DIGEST), threading.Event()
        )


def test_large_download_is_fetched_as_parallel_ranges_and_verified(tmp_path, monkeypatch):
    monkeypatch.delenv("DOWNLOAD_PARTS", raising=False)
    seen = []
    assert _fetch(tmp_path, _range_server(BODY, seen=seen)) == len(BODY)
    assert (tmp_path / "in").read_bytes() == BODY
    assert len(seen) == 4 and all(h and h.startswith("bytes=") for h in seen)
    assert oct((tmp_path / "in").stat().st_mode & 0o777) == "0o600"


def test_download_parts_setting_can_restore_one_stream(tmp_path, monkeypatch):
    monkeypatch.setenv("DOWNLOAD_PARTS", "1")
    seen = []
    _fetch(tmp_path, _range_server(BODY, seen=seen))
    assert seen == [None] and (tmp_path / "in").read_bytes() == BODY


def test_server_that_ignores_ranges_is_read_in_one_stream(tmp_path, monkeypatch):
    monkeypatch.delenv("DOWNLOAD_PARTS", raising=False)
    assert _fetch(tmp_path, _range_server(BODY, ignore_ranges=True)) == len(BODY)
    assert (tmp_path / "in").read_bytes() == BODY


def test_one_failed_part_is_retried_once(tmp_path, monkeypatch):
    monkeypatch.delenv("DOWNLOAD_PARTS", raising=False)
    tried = []

    def fail(request):
        if request.headers["range"].startswith("bytes=0-") and not tried:
            tried.append(1)
            return 503
        return None

    assert _fetch(tmp_path, _range_server(BODY, fail=fail)) == len(BODY)
    assert (tmp_path / "in").read_bytes() == BODY and tried


@pytest.mark.parametrize("status,error", [(404, executor.MediaUnavailable), (503, executor.StorageUnavailable)])
def test_range_failures_map_to_the_same_errors_as_a_single_stream(tmp_path, monkeypatch, status, error):
    monkeypatch.delenv("DOWNLOAD_PARTS", raising=False)
    with pytest.raises(error):
        _fetch(tmp_path, _range_server(BODY, fail=lambda r: status))


def test_wrong_bytes_are_rejected_after_a_parallel_download(tmp_path, monkeypatch):
    monkeypatch.delenv("DOWNLOAD_PARTS", raising=False)
    with pytest.raises(ValueError):
        _fetch(tmp_path, _range_server(BODY), sha="0" * 64)


def test_lost_lease_stops_a_parallel_download(tmp_path, monkeypatch):
    monkeypatch.delenv("DOWNLOAD_PARTS", raising=False)
    lost = threading.Event()
    lost.set()
    with httpx.Client(transport=_range_server(BODY)) as client:
        with pytest.raises(executor.LeaseLost):
            executor.fetch_media(client, MEDIA, tmp_path / "in", len(BODY), DIGEST, lost)


def test_small_files_stay_on_one_stream(tmp_path, monkeypatch):
    monkeypatch.delenv("DOWNLOAD_PARTS", raising=False)
    small = b"x" * 1000
    seen = []
    _fetch(tmp_path, _range_server(small, seen=seen), size=1000, sha=_hashlib.sha256(small).hexdigest())
    assert seen == [None]
