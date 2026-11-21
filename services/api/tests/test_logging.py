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
    assert response.status_code == 202 and response.json() == {"accepted": 1}
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
    ],
)
async def test_client_events_reject_anything_off_the_whitelist(backend, event):
    body = {"app": "student", "platform": "web", "events": [event]}
    response = await backend.client.post(
        "/v1/client-events", headers=backend.headers("student1"), json=body
    )
    assert response.status_code == 422, response.text


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
