"""Worker and agent structured logging: shape, redaction, de-duplication, job events."""

import json

import httpx

from facetrack_worker import agent, executor, log


def events(capsys):
    return [json.loads(line) for line in capsys.readouterr().out.splitlines() if line.startswith("{")]


def test_events_are_single_json_lines_with_a_fixed_shape(capsys):
    log.event("probe", job_id="j1", duration_ms=12)
    (entry,) = events(capsys)
    assert entry["service"] == "worker" and entry["event"] == "probe" and entry["level"] == "info"
    assert entry["job_id"] == "j1" and entry["duration_ms"] == 12 and "ts" in entry


def test_nothing_sensitive_can_be_logged(capsys):
    log.event(
        "probe",
        student_name="Asha Rao",
        enrollment_number="0042",
        media_url="https://storage.invalid/x?signature=abc",
        vectors=[0.1],
        authorization="Bearer abc",
        similarity=0.9,
        detail="mail asha@example.test",
        jwt="eyJhbGciOiJFUzI1NiJ9.payload.sig",
        quality={"sampled_frames": 12, "template_count": 3},
    )
    text = json.dumps(events(capsys))
    for secret in ("Asha", "0042", "storage.invalid", "Bearer", "asha@", "eyJ", "0.9", "template"):
        assert secret not in text, secret
    assert "sampled_frames" in text


def test_resources_reads_what_the_host_offers_without_failing():
    fields = log.resources("/")
    assert fields["disk_free_gb"] >= 0 and 0 <= fields["disk_used_percent"] <= 100
    # /proc is absent on a Mac; where it exists the numbers are sane.
    if "mem_total_mb" in fields:
        assert fields["mem_total_mb"] >= fields["mem_available_mb"] > 0
        assert fields["load1"] >= 0


def test_a_recurring_problem_is_logged_once_then_summarised(capsys, monkeypatch):
    agent._noticed.clear()
    now = [1000.0]
    monkeypatch.setattr(agent.time, "monotonic", lambda: now[0])
    for _ in range(5):
        agent.notice("Enrolment agent waiting for local API/broker.", "error", status=503)
        now[0] += 5
    assert len(events(capsys)) == 1  # 25 s of outage: one line, not five
    now[0] += 60
    agent.notice("Enrolment agent waiting for local API/broker.", "error", status=503)
    (again,) = events(capsys)
    assert again["repeats"] == 4 and again["status"] == 503


def test_an_expired_credential_is_logged_as_an_error_with_its_status(capsys, monkeypatch):
    agent._noticed.clear()
    agent.PENDING.clear()
    monkeypatch.setattr(agent, "backlog", lambda: 0)
    request = httpx.Request("POST", "http://api/internal/v1/jobs/claim")

    def reject(*args):
        raise httpx.HTTPStatusError("x", request=request, response=httpx.Response(401, request=request))

    monkeypatch.setattr(agent, "api", reject)
    agent.cycle(None, 1e18)
    entry = [e for e in events(capsys) if e["event"] == "agent_notice"][-1]
    assert entry["level"] == "error" and entry["status"] == 401
    assert "credential rejected or expired" in entry["message"]


def test_a_failed_job_records_its_code_and_the_stage_it_reached(capsys, monkeypatch):
    sent = []
    monkeypatch.setattr(executor, "post_with_retry", lambda client, path, body, **k: sent.append(body))
    executor.post_fail(None, "job-1", 3, "WORKER_ERROR", True, "download")
    (entry,) = events(capsys)
    assert entry["event"] == "job_failed" and entry["level"] == "warning"
    assert entry["job_id"] == "job-1" and entry["code"] == "WORKER_ERROR"
    assert entry["stage"] == "download" and entry["retryable"] is True
    assert sent == [{"epoch": 3, "code": "WORKER_ERROR", "retryable": True}]


def test_routine_notes_are_not_announced_as_recoveries(capsys):
    agent._noticed.clear()
    agent.notice("Worker busy; not claiming more jobs.", "info", backlog=1)
    capsys.readouterr()
    agent.recovered()
    assert events(capsys) == []
    assert not agent._noticed  # and the note can be logged again next time


def test_recovery_reports_what_was_suppressed(capsys):
    agent._noticed.clear()
    for _ in range(4):
        agent.notice("API down", "error")
    capsys.readouterr()
    agent.recovered()
    (entry,) = events(capsys)
    assert entry["event"] == "agent_recovered" and entry["cleared"] == 1 and entry["suppressed"] == 3


def test_non_finite_numbers_and_lists_are_not_logged(capsys):
    log.event("probe", ratio=float("nan"), scores=[0.1], good=2.5)
    (entry,) = events(capsys)
    assert "ratio" not in entry and "scores" not in entry and entry["good"] == 2.5


def test_a_pending_lease_survives_an_unrelated_value_error(monkeypatch):
    agent.PENDING.clear()
    agent._noticed.clear()
    monkeypatch.setattr(agent, "backlog", lambda: 0)
    agent.PENDING["lease"] = ({"id": "j", "lease_epoch": 1}, agent.time.monotonic())

    def boom(name, args):
        raise ValueError("encode error")

    monkeypatch.setattr(agent.app, "send_task", boom)
    agent.cycle(None, 1e18)
    assert agent.PENDING  # kept, so the hand-off is retried within its window
    agent.PENDING.clear()


def test_timing_fields_are_logged_even_when_their_name_mentions_a_banned_word(capsys):
    # "embedding_ms" is a duration, not an embedding; the redaction used to drop it.
    log.event("t", timings={"embedding_ms": 12.5, "embedding": 3, "decoding_ms": 1.0}, embedding_ms=7)
    line = capsys.readouterr().out
    assert '"embedding_ms":12.5' in line.replace(" ", "") and '"embedding_ms":7' in line.replace(" ", "")
    assert '"embedding":3' not in line.replace(" ", "")


def test_timings_with_a_redacted_word_in_the_name_still_reach_the_log(capsys):
    """embedding_ms contains 'embedding', a banned word; durations are named *_ms and are safe."""
    timings = {"decoding_ms": 10.5, "embedding_ms": 220.25, "embed_every": 2.0, "embedded_faces": 40.0}
    log.event("inference_done", job_id="j1", timings=timings, embedding_ms=12)
    (entry,) = events(capsys)
    assert entry["timings"] == timings and entry["embedding_ms"] == 12
    # the exemption is for durations only: a score or a vector under the same word stays out
    log.event("probe", embedding=0.5, embedding_score=0.9, similarity_ms=3, note="x")
    (entry,) = events(capsys)
    assert "embedding" not in entry and "embedding_score" not in entry and entry["note"] == "x"


def test_a_jobs_ids_are_attached_to_every_line_that_names_it(capsys):
    log.bind("job-1", session_id="s-1", capture_id="c-1")
    try:
        log.event("download_done", job_id="job-1", bytes=5)
        log.event("lease_lost", "warning", job_id="job-1", reason="heartbeat_silent")
        log.event("download_done", job_id="job-2", bytes=5)  # another job: nothing attached
        log.event("resources", backlog=0)
    finally:
        log.unbind("job-1")
    log.event("job_done", job_id="job-1")
    first, second, other, resources, after = events(capsys)
    assert first["session_id"] == "s-1" and first["capture_id"] == "c-1"
    assert second["session_id"] == "s-1"
    assert "session_id" not in other and "session_id" not in resources and "session_id" not in after


def test_the_job_context_stays_small(capsys):
    for n in range(200):
        log.bind(f"job-{n}", session_id="s")
    assert len(log._context) <= 64
    log._context.clear()
