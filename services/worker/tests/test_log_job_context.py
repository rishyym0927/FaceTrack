"""A job's log lines name the class and the segment, even those from the failure path."""

import json

from facetrack_worker import executor, log

from test_executor import JOB, MEDIA, mocked  # noqa: F401

SESSION = "11111111-1111-4111-8111-111111111111"
CAPTURE = "22222222-2222-4222-8222-222222222222"


def logged(capsys):
    return [json.loads(x) for x in capsys.readouterr().out.splitlines() if x.startswith("{")]


def test_every_line_of_a_failing_job_carries_session_and_capture(mocked, capsys):  # noqa: F811
    mocked(
        {"media_url": MEDIA, "byte_size": 1, "source_sha256": "x", "kind": "recognition",
         "session_id": SESSION, "capture_id": CAPTURE},
        {"media": [404]},
    )
    executor.enroll(JOB, 1)
    lines = [x for x in logged(capsys) if x.get("job_id") == JOB]
    assert {x["event"] for x in lines} >= {"job_start", "job_failed"}
    after_input = [x for x in lines if x["event"] != "job_start"]
    assert after_input and all(x["session_id"] == SESSION and x["capture_id"] == CAPTURE for x in after_input)
    assert JOB not in log._context  # nothing stays bound once the job returns
