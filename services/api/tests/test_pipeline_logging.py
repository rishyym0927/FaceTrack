"""Every job log line names the class, the segment and the job; failures log route and duration."""

import json
import logging

from test_attendance import captured, recognition_ready
from test_biometrics import bio as bio  # noqa: F401

LOGGER = "uvicorn.error.facetrack"


def lines(caplog, event):
    found = []
    for record in caplog.records:
        if record.name == LOGGER:
            data = json.loads(record.getMessage())
            if data["event"] == event:
                found.append(data)
    return found


async def test_a_claimed_job_logs_session_capture_and_queue_wait(bio, caplog):
    caplog.set_level(logging.INFO, logger=LOGGER)
    b = bio
    s = await recognition_ready(b)
    cap, jid, epoch, data = await captured(b, s)
    claimed = lines(caplog, "job_claimed")[-1]
    assert claimed["job_id"] == jid and claimed["session_id"] == s["id"]
    assert claimed["capture_id"] == cap["id"] and claimed["attempts"] == 1 and claimed["epoch"] == epoch
    assert 0 <= claimed["queue_wait_ms"] < 60_000
    # the worker is told the ids too, so its own lines can carry them
    assert data["session_id"] == s["id"] and data["capture_id"] == cap["id"]


async def test_recognition_complete_names_the_capture_and_attempt(bio, caplog):
    caplog.set_level(logging.INFO, logger=LOGGER)
    b = bio
    s = await recognition_ready(b)
    cap, jid, epoch, data = await captured(b, s)
    body = {k: data[k] for k in ("generation", "source_sha256", "model_hash", "profile_hash", "roster_hash")}
    body.update(
        epoch=epoch, processed_sha256="e" * 64, proposals=[], unknown_observations=0,
        quality={"sampled_frames": 12, "detections": 5, "quality_rejects": 1},
        timings={"processing_total_ms": 5, "embedding_ms": 2.5}, reject_reasons={"small": 1},
        face_px_median=64, sample_fps=4.0,
    )
    assert (await b.client.post(f"/internal/v1/jobs/{jid}/complete", headers=b.wh, json=body)).status_code == 200
    done = lines(caplog, "recognition_complete")[-1]
    assert done["capture_id"] == cap["id"] and done["job_id"] == jid and done["session_id"] == s["id"]
    assert done["attempts"] == 1 and done["timings"]["embedding_ms"] == 2.5


async def test_a_failed_job_names_its_capture(bio, caplog):
    caplog.set_level(logging.INFO, logger=LOGGER)
    b = bio
    s = await recognition_ready(b)
    cap, jid, epoch, _ = await captured(b, s)
    body = {"epoch": epoch, "code": "WORKER_ERROR", "retryable": False}
    r = await b.client.post(f"/internal/v1/jobs/{jid}/fail", headers=b.wh, json=body)
    assert r.status_code in (200, 204), r.text
    failed = lines(caplog, "job_failed")[-1]
    assert failed["job_id"] == jid and failed["capture_id"] == cap["id"] and failed["code"] == "WORKER_ERROR"


async def test_an_unhandled_error_logs_route_status_and_duration(bio, caplog):
    import pytest

    caplog.set_level(logging.INFO, logger=LOGGER)
    b = bio

    @b.app.get("/v1/sessions/{identifier}/boom")
    async def boom(identifier: str):
        raise RuntimeError("secret detail that must not be logged")

    sid = "11111111-1111-1111-1111-111111111111"
    with pytest.raises(RuntimeError):  # the test transport re-raises what the server answered with 500
        await b.client.get(f"/v1/sessions/{sid}/boom", headers=b.headers("teacher"))
    entry = lines(caplog, "unhandled_error")[-1]
    assert entry["route"] == "/v1/sessions/{identifier}/boom" and entry["status"] == 500
    assert entry["method"] == "GET" and entry["duration_ms"] >= 0 and entry["session_id"] == sid
    assert entry["error"] == "RuntimeError" and "secret detail" not in caplog.text
