"""Structured logging: correlation ids, redaction and the client-events route."""

import json
import logging

import pytest

from app import client_events, logs

LOGGER = "uvicorn.error.facetrack"


def lines(caplog, event=None):
    out = []
    for record in caplog.records:
        if record.name != LOGGER:
            continue
        data = json.loads(record.getMessage())
        if event is None or data["event"] == event:
            out.append(data)
    return out


def test_sensitive_fields_and_values_never_reach_the_log():
    entry = logs.record(
        "probe",
        request_id="r1",
        official_name="Asha Rao",
        enrollment_number="0042",
        email="asha@example.test",
        authorization="Bearer abc",
        signed_url="https://x.invalid/?token=abc",
        vector=[0.1, 0.2],
        similarity=0.91,
        # innocent field names carrying secret-looking values are still scrubbed
        note="contact asha@example.test",
        link="https://storage.invalid/object?signature=abc",
        jwt="eyJhbGciOiJFUzI1NiJ9.payload.sig",
        counts={"sampled_frames": 12, "template_x": 1, "ok": 2},
        ok=True,
    )
    text = json.dumps(entry)
    for secret in ("Asha", "0042", "asha@", "Bearer", "signature=", "eyJ", "0.91"):
        assert secret not in text, secret
    assert entry["request_id"] == "r1" and entry["ok"] is True
    assert entry["counts"] == {"sampled_frames": 12, "ok": 2}
    assert entry["service"] == "api" and entry["event"] == "probe" and "ts" in entry


def test_long_text_is_truncated_and_none_dropped():
    entry = logs.record("probe", detail="x" * 1000, missing=None)
    assert len(entry["detail"]) == logs.MAX_TEXT and "missing" not in entry


def test_correlation_ids_come_from_the_route_template():
    params = {"identifier": "11111111-1111-1111-1111-111111111111"}
    assert logs.correlation("/v1/sessions/{identifier}/attendance", params) == {
        "session_id": params["identifier"]
    }
    assert logs.correlation("/v1/captures/{identifier}/upload-grant", params) == {
        "capture_id": params["identifier"]
    }
    assert logs.correlation("/internal/v1/jobs/{identifier}/fail", params) == {
        "job_id": params["identifier"]
    }
    assert logs.correlation("/v1/me", params) == {}


def test_budget_is_a_sliding_window_per_key():
    now = [0.0]
    budget = logs.Budget(limit=5, seconds=10, clock=lambda: now[0])
    assert budget.take("a", 3) and budget.take("a", 2)
    assert not budget.take("a") and budget.take("b")
    now[0] = 11
    assert budget.take("a", 5)


async def test_every_request_is_logged_with_ids_and_never_the_token(backend, caplog):
    b = backend
    caplog.set_level(logging.INFO, logger=LOGGER)
    session = "22222222-2222-2222-2222-222222222222"
    headers = b.headers("teacher")
    response = await b.client.get(f"/v1/sessions/{session}/attendance", headers=headers)
    entries = lines(caplog, "request")
    assert entries, "no request log line"
    last = entries[-1]
    assert last["route"] == "/v1/sessions/{identifier}/attendance"
    assert last["session_id"] == session
    assert last["status"] == response.status_code and last["method"] == "GET"
    assert last["request_id"] == response.headers["x-request-id"]
    assert last["duration_ms"] >= 0
    if response.status_code >= 400:
        assert last["code"] == response.json()["error"]["code"]
    token = headers["Authorization"].split()[1]
    assert token not in caplog.text and "Bearer" not in caplog.text


async def test_errors_are_logged_with_their_code_at_warning_level(backend, caplog):
    caplog.set_level(logging.INFO, logger=LOGGER)
    response = await backend.client.get("/v1/me")  # no token
    assert response.status_code == 401
    entry = lines(caplog, "request")[-1]
    assert entry["status"] == 401 and entry["code"] == "AUTHENTICATION_REQUIRED"
    record = next(r for r in caplog.records if r.name == LOGGER)
    assert record.levelno == logging.WARNING


def batch(**event):
    return {
        "app": "teacher",
        "platform": "android",
        "version": "1.0.3",
        "events": [{"name": "upload_retry", **event}],
    }


async def test_client_events_are_accepted_and_logged_without_identity(backend, caplog):
    b = backend
    caplog.set_level(logging.INFO, logger=LOGGER)
    session = "33333333-3333-3333-3333-333333333333"
    response = await b.client.post(
        "/v1/client-events",
        headers=b.headers("teacher"),
        json=batch(session_id=session, attempt=2, code="CONNECTION", seconds=4.5, bytes=1234),
    )
    assert response.status_code == 202 and response.json() == {"accepted": 1, "rejected": 0}
    entry = lines(caplog, "client_event")[-1]
    assert entry["kind"] == "upload_retry" and entry["session_id"] == session
    assert entry["attempt"] == 2 and entry["client"] == "teacher" and entry["platform"] == "android"
    assert entry["request_id"] == response.headers["x-request-id"]
    assert b.users["teacher"]["email"] not in caplog.text
    assert b.users["teacher"]["id"] not in caplog.text


async def test_client_events_require_sign_in(backend):
    response = await backend.client.post("/v1/client-events", json=batch())
    assert response.status_code == 401


@pytest.mark.parametrize(
    "event",
    [
        {"name": "login_form_submitted"},  # not on the whitelist
        {"name": "app_error", "email": "a@b.invalid"},  # unknown field
        {"name": "app_error", "message": "free text is not allowed"},
        {"name": "app_error", "code": "has spaces and \"quotes\""},
        {"name": "api_error", "route": "https://evil.invalid/x"},
        {"name": "api_error", "status": 99},
        {"name": "segment_recorded", "bytes": -1},
        {"name": "upload_done", "age_ms": 10**9},
    ],
)
async def test_client_events_reject_anything_off_the_whitelist(backend, caplog, event):
    caplog.set_level(logging.INFO, logger=LOGGER)
    body = {"app": "student", "platform": "web", "events": [event]}
    response = await backend.client.post(
        "/v1/client-events", headers=backend.headers("student1"), json=body
    )
    # The batch is answered, the event is skipped and counted, and nothing it carried is logged.
    assert response.status_code == 202, response.text
    assert response.json() == {"accepted": 0, "rejected": 1}
    assert not lines(caplog, "client_event")
    assert lines(caplog, "client_events_rejected")[-1]["count"] == 1
    for fragment in ("evil.invalid", "a@b.invalid", "free text", "quotes", "login_form"):
        assert fragment not in caplog.text


async def test_one_unknown_event_does_not_cost_the_rest_of_the_batch(backend, caplog):
    caplog.set_level(logging.INFO, logger=LOGGER)
    session = "44444444-4444-4444-4444-444444444444"
    body = {
        "app": "teacher",
        "platform": "web",
        "events": [
            {"name": "segment_recorded", "session_id": session, "count": 1, "bytes": 99},
            {"name": "event_from_a_newer_app"},
            {"name": "camera_recovered", "session_id": session, "code": "switched"},
            {"name": "upload_done", "session_id": session, "count": 1, "duration_ms": 8000},
        ],
    }
    response = await backend.client.post(
        "/v1/client-events", headers=backend.headers("teacher"), json=body
    )
    assert response.status_code == 202 and response.json() == {"accepted": 3, "rejected": 1}
    assert [e["kind"] for e in lines(caplog, "client_event")] == [
        "segment_recorded",
        "camera_recovered",
        "upload_done",
    ]
    warning = lines(caplog, "client_events_rejected")[-1]
    assert warning["level"] == "warning" and warning["count"] == 1


async def test_events_report_when_they_happened_and_on_what_kind_of_device(backend, caplog):
    caplog.set_level(logging.INFO, logger=LOGGER)
    body = {
        "app": "student",
        "platform": "android",
        "version": "abc1234",
        "device_class": "phone",
        "network": "cellular",
        "net_class": "3g",
        "downlink_mbps": 1.4,
        "rtt_ms": 300,
        "events": [
            {"name": "scan_paused", "code": "hidden", "age_ms": 5000},
            {"name": "scan_resumed", "code": "resumed", "seconds": 4.2},
            {"name": "recognition_load_failed", "route": "/v1/sessions/{id}/attendance", "status": 503},
        ],
    }
    response = await backend.client.post(
        "/v1/client-events", headers=backend.headers("student1"), json=body
    )
    assert response.status_code == 202
    first, second, third = lines(caplog, "client_event")
    assert first["device_class"] == "phone" and first["network"] == "cellular"
    assert first["net_class"] == "3g" and first["downlink_mbps"] == 1.4 and first["rtt_ms"] == 300
    # event_at is the arrival time minus age_ms: five seconds earlier than this line's own ts
    from datetime import datetime

    arrived = datetime.fromisoformat(first["ts"])
    happened = datetime.fromisoformat(first["event_at"])
    assert 4.5 < (arrived - happened).total_seconds() < 6
    assert "event_at" not in second and second["seconds"] == 4.2
    assert third["kind"] == "recognition_load_failed" and third["http_status"] == 503


@pytest.mark.parametrize(
    "extra",
    [
        {"device_class": "Pixel 7 Pro"},  # a model name is not a class
        {"network": "Hostel-WiFi-5G"},  # an SSID must never be accepted
        {"net_class": "5g"},
        {"rtt_ms": -1},
    ],
)
async def test_device_and_network_context_is_a_fixed_vocabulary(backend, extra):
    body = {**batch(), **extra}
    response = await backend.client.post(
        "/v1/client-events", headers=backend.headers("teacher"), json=body
    )
    assert response.status_code == 422


def test_every_event_the_apps_emit_is_on_the_whitelist():
    """The Dart whitelist and the server's must be the same list; a name missing on the server
    used to make the whole batch fail (camera_recovered)."""
    import re
    from pathlib import Path

    root = Path(__file__).resolve().parents[3]
    dart = (root / "packages/app_core/lib/src/diagnostics.dart").read_text()
    known = re.search(r"static const knownEvents = \{(.*?)\};", dart, re.S).group(1)
    names = set(re.findall(r"'([a-z_]+)'", known))
    assert names == set(client_events.EVENT_NAMES)
    emitted = set()
    for source in ("apps/teacher/lib", "apps/student/lib", "packages/capture/lib"):
        for path in (root / source).rglob("*.dart"):
            emitted |= set(
                re.findall(r"onEvent\??\.call\(\s*'([a-z_]+)'", path.read_text())
            )
    assert emitted <= set(client_events.EVENT_NAMES), emitted - set(client_events.EVENT_NAMES)


async def test_client_events_batches_are_bounded(backend):
    b = backend
    too_many = {
        "app": "teacher",
        "platform": "web",
        "events": [{"name": "app_error"}] * 51,
    }
    assert (
        await b.client.post("/v1/client-events", headers=b.headers("teacher"), json=too_many)
    ).status_code == 422
    empty = {"app": "teacher", "platform": "web", "events": []}
    assert (
        await b.client.post("/v1/client-events", headers=b.headers("teacher"), json=empty)
    ).status_code == 422


async def test_a_runaway_client_is_rate_limited_not_logged(backend, caplog, monkeypatch):
    b = backend
    monkeypatch.setattr(client_events, "budget", logs.Budget(limit=3, seconds=600))
    caplog.set_level(logging.INFO, logger=LOGGER)
    ok = await b.client.post("/v1/client-events", headers=b.headers("teacher"), json=batch())
    assert ok.status_code == 202
    flood = {"app": "teacher", "platform": "web", "events": [{"name": "app_error"}] * 5}
    limited = await b.client.post("/v1/client-events", headers=b.headers("teacher"), json=flood)
    assert limited.status_code == 429 and limited.json()["error"]["retryable"] is True
    assert len(lines(caplog, "client_event")) == 1  # only the first batch was logged


def test_events_carry_their_level_so_errors_can_be_found():
    assert logs.record("x", logging.ERROR)["level"] == "error"
    assert logs.record("x", logging.WARNING)["level"] == "warning"
    assert logs.record("x")["level"] == "info"


def test_non_finite_numbers_and_lists_are_never_logged():
    entry = logs.record(
        "probe", ratio=float("nan"), limit=float("inf"), scores=[0.1, 0.2], ok=1.5,
        counts={"good": 1.0, "bad": float("nan")},
    )
    assert "ratio" not in entry and "limit" not in entry and "scores" not in entry
    assert entry["ok"] == 1.5 and entry["counts"] == {"good": 1.0}
    json.loads(json.dumps(entry, allow_nan=False))  # strict JSON, no NaN or Infinity


async def test_only_a_real_institute_id_is_logged_from_the_header(backend, caplog):
    b = backend
    caplog.set_level(logging.INFO, logger=LOGGER)
    headers = {**b.headers("teacher"), "X-Institute-ID": "anything the client likes <script>"}
    await b.client.get("/v1/me", headers=headers)
    entry = lines(caplog, "request")[-1]
    assert "institute_id" not in entry and "script" not in caplog.text
    await b.client.get("/v1/me", headers=b.headers("teacher"))
    assert lines(caplog, "request")[-1]["institute_id"] == b.ids["institute"]


async def test_a_reported_http_status_is_not_mistaken_for_a_server_error(backend, caplog):
    b = backend
    caplog.set_level(logging.INFO, logger=LOGGER)
    body = {
        "app": "teacher",
        "platform": "web",
        "events": [{"name": "api_error", "status": 503, "route": "/v1/me"}],
    }
    await b.client.post("/v1/client-events", headers=b.headers("teacher"), json=body)
    entry = lines(caplog, "client_event")[-1]
    assert entry["http_status"] == 503 and "status" not in entry


def test_uvicorn_tracebacks_and_secret_text_are_redacted(caplog):
    import logging
    import sys

    from app import logs

    logs.install_redaction()
    try:
        raise ValueError("student ada@example.test enrolment 0001")
    except ValueError:
        exc_info = sys.exc_info()
    seen = []

    class Capture(logging.Handler):
        def emit(self, record):
            seen.append((record.getMessage(), record.exc_info, record.exc_text))

    handler = Capture()
    log = logging.getLogger("uvicorn.error")
    log.addHandler(handler)
    try:
        log.error("Exception in ASGI application", exc_info=exc_info)
        log.error("fetched https://x.test/a?token=abc for ada@example.test")
    finally:
        log.removeHandler(handler)
    message, info, text = seen[0]
    assert message.startswith("Unhandled ValueError at ") and info is None and text is None
    assert "ada@example.test" not in message and "0001" not in message
    assert "ada@example.test" not in seen[1][0] and "token=abc" not in seen[1][0]


def test_timings_with_a_redacted_word_in_the_name_still_reach_the_log():
    """embedding_ms is a duration: it contains the banned word 'embedding' but must be logged."""
    timings = {"decoding_ms": 10.5, "embedding_ms": 220.25, "embed_every": 2.0, "embedded_faces": 40.0}
    entry = logs.record("recognition_complete", timings=timings, embedding_ms=5)
    assert entry["timings"] == timings and entry["embedding_ms"] == 5
    # only durations get the exemption
    entry = logs.record("probe", embedding_score=0.9, vector_ms=1, quality={"embedding": 1, "ok": 2})
    assert "embedding_score" not in entry and entry["quality"] == {"ok": 2}


def test_a_recognition_summary_keeps_every_diagnostic_field():
    entry = logs.record(
        "recognition_complete",
        session_id="s",
        capture_id="c",
        job_id="j",
        roster=24,
        recognised=20,
        quality={"sampled_frames": 80, "detections": 70, "quality_rejects": 44, "duplicate_frames": 0},
        reject_reasons={"blur": 6, "small": 37, "edge": 1},
        face_px_median=78,
        sample_fps=4.01,
        queue_wait_ms=1200,
        attempts=1,
        timings={"processing_total_ms": 3587.2, "embedding_ms": 900.0},
        reasons={"recognized": 20, "not_seen": 3, "look_alike": 1},
    )
    for key in ("capture_id", "queue_wait_ms", "attempts", "face_px_median", "sample_fps"):
        assert key in entry, key
    assert entry["reject_reasons"] == {"blur": 6, "small": 37, "edge": 1}
    assert entry["reasons"] == {"recognized": 20, "not_seen": 3, "look_alike": 1}
