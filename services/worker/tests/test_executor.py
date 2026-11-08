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
