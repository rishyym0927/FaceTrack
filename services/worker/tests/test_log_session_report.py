"""scripts/session_report.py on synthetic logs: parsing, correlation, findings, privacy."""

import gzip
import importlib.util
import json
import re
import subprocess
import sys
from datetime import UTC, datetime, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location("session_report", ROOT / "scripts" / "session_report.py")
report = importlib.util.module_from_spec(SPEC)
sys.modules["session_report"] = report
SPEC.loader.exec_module(report)

SESSION = "aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa"
OTHER = "bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb"
T0 = datetime(2026, 11, 24, 9, 0, 0, tzinfo=UTC)


def at(seconds):
    return (T0 + timedelta(seconds=seconds)).isoformat(timespec="milliseconds")


def api(seconds, event, level="info", **fields):
    return "INFO:     " + json.dumps({"ts": at(seconds), "level": level, "service": "api", "event": event, **fields})


def worker(seconds, event, level="info", **fields):
    body = json.dumps({"ts": at(seconds), "level": level, "service": "worker", "event": event, **fields})
    return f"[2026-11-24 09:00:{seconds % 60:02d},000: WARNING/MainProcess] {body}"


def client(seconds, kind, received=None, **fields):
    """A client event: logged when the batch arrived, but it happened at ``seconds``."""
    arrived = seconds if received is None else received
    return api(arrived, "client_event", kind=kind, client="teacher", platform="android", version="abc1234",
               device_class="phone", network="wifi", net_class="4g", **{"event_at": at(seconds)} if received else {}, **fields)


def request(seconds, method, route, status=200, ms=50, **fields):
    level = "error" if status >= 500 else "warning" if status >= 400 else "info"
    return api(seconds, "request", level, request_id=f"{seconds:08d}-req", method=method, route=route,
               status=status, duration_ms=ms, db_checkout_ms=0.1, **fields)


def job(n, started, *, detections=40, rejects=None, queue=None, mbps=40.0, reasons=None, recognised=20, roster=24, fail=None):
    job_id = f"{n:08d}-0000-4000-8000-000000000000"
    capture = f"cccccccc-000{n}-4000-8000-000000000000"
    rejects = rejects if rejects is not None else {"small": 2}
    lines = [
        request(started - 3, "POST", "/v1/captures/{identifier}/upload-complete", 202, capture_id=capture),
        api(started, "job_claimed", job_id=job_id, capture_id=capture, session_id=SESSION, queue_wait_ms=queue or 2500, attempts=1),
        worker(started, "job_dispatched", job_id=job_id),
        worker(started + 1, "job_start", job_id=job_id, session_id=SESSION, capture_id=capture, epoch=1),
        worker(started + 3, "download_done", job_id=job_id, session_id=SESSION, bytes=11_000_000,
               duration_ms=int(11_000_000 * 8 / 1000 / mbps), parts=4, mbps=mbps),
    ]
    if fail:
        lines += [
            worker(started + 4, "job_failed", "warning", job_id=job_id, code=fail, retryable=True, stage="download"),
            api(started + 5, "job_failed", "warning", job_id=job_id, kind="recognition", code=fail, attempts=1, will_retry=False),
            worker(started + 6, "lease_lost", "warning", job_id=job_id, reason="api_rejected", stage="complete"),
        ]
        return lines
    timings = {"decoding_ms": 900.0, "detection_ms": 1500.0, "embedding_ms": 2200.0, "matching_ms": 40.0,
               "embed_every": 1.0, "embedded_faces": 30.0, "processing_total_ms": 2500.0}
    quality = {"sampled_frames": 80, "detections": detections, "quality_rejects": sum(rejects.values()), "duplicate_frames": 0}
    lines += [
        worker(started + 8, "inference_done", job_id=job_id, session_id=SESSION, kind="recognition", inference_ms=4500,
               timings=timings, quality=quality, reject_reasons=rejects, face_px_median=120, sample_fps=4.0),
        api(started + 9, "recognition_complete", session_id=SESSION, capture_id=capture, job_id=job_id, roster=roster,
            recognised=recognised, quality=quality, reject_reasons=rejects, face_px_median=120, sample_fps=4.0,
            timings=timings, reasons=reasons or {"recognized": recognised, "not_seen": roster - recognised}, queue_wait_ms=queue or 2500),
        worker(started + 10, "job_done", job_id=job_id, session_id=SESSION, total_ms=9500),
    ]
    return lines


def healthy(stop=True, uploads=3, diagnostics=True):
    lines = [request(0, "POST", "/v1/sessions/{identifier}/open", session_id=SESSION),
             client(2, "scan_started", received=14, session_id=SESSION)]
    for n in (1, 2, 3):
        recorded = 20 * n
        lines += [client(recorded, "segment_recorded", received=recorded + 8, session_id=SESSION, count=n, bytes=11_000_000)]
        if n <= uploads:
            lines += [client(recorded + 9, "upload_done", received=recorded + 10, session_id=SESSION, count=n, attempt=0, duration_ms=8800)]
        lines += job(n, recorded + 12)
    if stop:
        lines += [client(70, "scan_stopped", received=71, session_id=SESSION, count=3)]
    if not diagnostics:
        lines = [l for l in lines if "client_event" not in l]
    for minute in range(3):
        lines.append(worker(minute * 60, "resources", backlog=0, load1=1.0, cpu_percent=30.0, mem_available_mb=9000,
                            mem_total_mb=15983, disk_free_gb=40.0))
    return lines


def run(lines, *args):
    events, total = report.read_events(lines)
    return report.make_report(events, total, SESSION, 10**9, None, None, "test")


# --------------------------------------------------------------------------------------------
def test_a_healthy_class_reports_no_problems():
    text = run(healthy())
    assert "**PROBLEM**" not in text
    assert "segments recorded 3, uploads finished 3" in text
    assert "3 recognition job(s) seen, 3 with a stored result" in text
    assert "| 1 | 00000001 |" in text and "recognized 20, not_seen 4" in text


def test_every_line_format_is_understood_and_duplicates_collapse():
    celery = worker(5, "job_start", job_id="j1")
    uvicorn = api(5, "request", method="GET", route="/v1/me", status=200)
    captured = "facetrack-worker-2 2026-11-24T09:00:05.000000000Z " + celery.split("] ", 1)[1]
    events, total = report.read_events(["noise", celery, uvicorn, captured, celery, "{bad json", ""])
    assert sorted(e.name for e in events) == ["job_start", "job_start", "request"]
    # the same line captured by two sources (same container) collapses; a different container does not
    events, _ = report.read_events([captured, captured, celery, celery])
    assert len(events) == 2 and {e.container for e in events} == {"facetrack-worker-2", None}


def test_idle_polling_and_health_checks_are_dropped():
    events, _ = report.read_events([
        request(1, "POST", "/internal/v1/jobs/claim", 204),
        request(2, "GET", "/health/ready"),
        request(3, "POST", "/internal/v1/jobs/claim", 200),
    ])
    assert [e.get("status") for e in events] == [200]


def test_client_events_are_placed_at_the_time_they_happened():
    events, _ = report.read_events([client(10, "segment_recorded", received=40, session_id=SESSION, count=1)])
    assert (events[0].at - events[0].ts).total_seconds() == -30
    timeline = report.build_timeline(events, T0, T0 + timedelta(minutes=5))
    assert timeline[0].startswith("09:00:10")


def test_upload_trouble_and_camera_problems_are_named_in_plain_words():
    lines = healthy() + [
        client(30, "upload_retry", session_id=SESSION, code="SocketException", attempt=1),
        client(31, "upload_retry", session_id=SESSION, code="SocketException", attempt=2),
        client(40, "upload_failed", session_id=SESSION, code="retries_exhausted", attempt=5),
        client(45, "camera_failed", session_id=SESSION, code="NotReadableError"),
        client(50, "scan_paused", session_id=SESSION, code="hidden"),
        client(55, "camera_interrupted", session_id=SESSION, code="recording_lost"),
        client(56, "recognition_load_failed", session_id=SESSION, http_status=503, route="/v1/sessions/{id}/attendance"),
    ]
    text = run(lines)
    assert "2 upload retries (reasons: SocketException 2)" in text
    assert "An upload FAILED (retries_exhausted, after 5 attempt(s))" in text
    assert "Camera failure at 09:00:45 (NotReadableError)" in text
    assert "scan was paused at 09:00:50 (hidden)" in text
    assert "camera was interrupted at 09:00:55 (recording_lost)" in text
    assert "could not load the recognition results" in text


def test_a_scan_that_never_stopped_and_missing_uploads_are_flagged():
    text = run(healthy(stop=False, uploads=2))
    assert "no 'scan stopped' event arrived" in text
    assert "3 segment(s) were recorded on the device but only 2 upload(s) finished" in text


def test_pipeline_problems_zero_faces_rejects_slow_download_queue_and_failures():
    lines = healthy()
    lines += job(4, 200, detections=0, rejects={})
    lines += job(5, 230, detections=100, rejects={"blur": 60, "small": 10}, mbps=5.0, queue=45000)
    lines += job(6, 260, fail="DOWNLOAD_UNAVAILABLE")
    text = run(lines)
    assert "NO face was detected at all" in text
    assert "70% of detected faces were rejected as unusable; mostly 'blur' (faces were blurred" in text
    assert "to download 11.0 MB from storage (about 5 Mbps)" in text
    assert "waited 45 s in the queue" in text
    assert "job 00000006 FAILED (DOWNLOAD_UNAVAILABLE, stage download" in text
    assert "lost its lease" in text


def test_server_errors_slow_requests_and_resources_are_reported_with_request_ids():
    lines = healthy() + [
        request(30, "POST", "/v1/sessions/{identifier}/close", 500, 90, session_id=SESSION, code="INTERNAL_ERROR"),
        request(31, "GET", "/v1/offerings", 200, 4800),
        api(32, "database_error", "error", request_id="deadbeef-1", error="OperationalError"),
        worker(60, "resources", cpu_percent=97.0, load1=9.5, mem_available_mb=400, mem_total_mb=15983, disk_free_gb=3.0, backlog=4),
        api(40, "processing_stalled", "warning", session_id=SESSION, queued=3),
    ]
    text = run(lines)
    assert "1 server error(s) 500 INTERNAL_ERROR on /v1/sessions/{identifier}/close (e.g. request 00000030" in text
    assert "1 slow request(s) (3 s or more) on /v1/offerings" in text
    assert "database error at 09:00:32 (OperationalError" in text
    assert "CPU reached 97%" in text and "Available memory fell to 400 MB" in text
    assert "Only 3.0 GB of disk was free" in text and "job backlog reached 4" in text
    assert "processing stalled" in text


def test_app_side_failures_without_a_server_trace_are_called_out():
    lines = healthy() + [client(40, "api_error", http_status=502, route="/v1/me")]
    text = run(lines)
    assert "have no matching error in the server log" in text


def test_missing_app_diagnostics_are_reported_not_hidden():
    assert "No app diagnostics arrived" in run(healthy(diagnostics=False))


def test_no_data_and_unknown_sessions_do_not_crash():
    events, total = report.read_events([])
    text = report.make_report(events, total, SESSION, 3600, None, None, "empty")
    assert "No log events were found" in text and "No log lines mention this session" in text
    assert "No class activity found" in report.make_report(events, total, None, 3600, None, None, "empty")


def test_latest_and_since_choose_sessions_from_the_logs():
    other = [l.replace(SESSION, OTHER).replace("2026-11-24T09:", "2026-11-24T11:") for l in healthy()]
    events, total = report.read_events(healthy() + other)
    latest = report.make_report(events, total, "latest", 10**9, None, None, "t")
    assert OTHER in latest and SESSION not in latest
    both = report.make_report(events, total, None, 10**9, None, None, "t")
    assert OTHER in both and SESSION in both
    narrow = report.make_report(events, total, None, 3600, None, None, "t")  # anchored on the last line
    assert OTHER in narrow and SESSION not in narrow


def test_the_report_never_contains_names_emails_or_tokens():
    lines = healthy() + [
        api(5, "request", request_id="r", method="GET", route="/v1/me", status=200, official_name="Asha Rao"),
        client(33, "app_error", session_id=SESSION, code="Bad_Thing"),
    ]
    text = run(lines)
    for secret in ("Asha", "@", "eyJ", "Bearer", "http://", "https://"):
        assert secret not in text, secret


def test_files_gz_and_directories_are_read(tmp_path):
    lines = healthy()
    (tmp_path / "api.log").write_text("\n".join(lines[:5]) + "\n")
    with gzip.open(tmp_path / "api.log.2.gz", "wt") as handle:
        handle.write("\n".join(lines[5:]) + "\n")
    (tmp_path / "notes.txt").write_text("ignored")
    events, _ = report.read_events(report.lines_from_dir(tmp_path))
    assert len(events) == len(report.read_events(lines)[0])


def test_the_command_line_runs_from_stdin():
    stdin = "\n".join(healthy())
    result = subprocess.run(
        [sys.executable, str(ROOT / "scripts" / "session_report.py"), "--stdin", "--no-db", SESSION],
        input=stdin, capture_output=True, text=True, timeout=60,
    )
    assert result.returncode == 0 and f"## Session `{SESSION}`" in result.stdout
    bad = subprocess.run(
        [sys.executable, str(ROOT / "scripts" / "session_report.py"), "--stdin", "--no-db", "not-a-session"],
        input="", capture_output=True, text=True, timeout=60,
    )
    assert bad.returncode == 2


# --------------------------------------------------------------------------------------------
# the database part
BANNED_SQL = ("student_id", "name_snapshot", "email", "enrol", "employee", "median_similarity",
              "official", "token", "template", "ciphertext", "face_templates")


def test_the_sql_never_selects_personal_columns():
    for name, statement in report.SQL.items():
        lowered = statement.lower()
        for word in BANNED_SQL:
            assert word not in lowered, (name, word)
        assert lowered.lstrip().startswith("select"), name


class FakeCursor:
    def __init__(self, conn):
        self.conn = conn
        self.rows = []

    def execute(self, sql, params=None):
        self.conn.executed.append(sql)
        if sql.startswith("SHOW"):
            self.rows = [(self.conn.read_only_value,)]
        elif sql.startswith("SET"):
            self.rows = []
        else:
            key = next(k for k, v in report.SQL.items() if v == sql)
            self.rows = self.conn.data.get(key, [])

    def fetchone(self):
        return self.rows[0] if self.rows else None

    def fetchall(self):
        return self.rows


class FakeConnection:
    def __init__(self, data=None, read_only_value="on"):
        self.executed, self.data, self.read_only_value = [], data or {}, read_only_value
        self.closed = False

    def cursor(self):
        return FakeCursor(self)

    def rollback(self):
        pass

    def close(self):
        self.closed = True


def test_the_database_connection_refuses_to_work_unless_it_is_read_only(monkeypatch):
    monkeypatch.setenv("MIGRATION_DATABASE_URL", "postgresql+psycopg://user:secret-pass@host/db")
    conn = FakeConnection(read_only_value="off")
    db = report.Database(connect=lambda url: conn)
    assert db.conn is None and db.error == "PermissionError" and conn.closed
    assert not any(sql.startswith("SELECT") for sql in conn.executed)


def test_database_errors_never_leak_the_connection_string(monkeypatch):
    monkeypatch.setenv("MIGRATION_DATABASE_URL", "postgresql://user:secret-pass@host/db")

    def refuse(url):
        raise RuntimeError(f"could not connect to {url}")

    db = report.Database(connect=refuse)
    assert db.error == "RuntimeError"
    events, total = report.read_events(healthy())
    text = report.make_report(events, total, SESSION, 10**9, db, None, "test")
    assert "secret-pass" not in text and "unavailable" in text and "RuntimeError" in text


def test_database_results_join_the_report(monkeypatch):
    monkeypatch.setenv("MIGRATION_DATABASE_URL", "postgresql://u:p@h/db")
    capture = "cccccccc-0001-4000-8000-000000000000"
    created = T0 + timedelta(seconds=20)
    data = {
        "session": [("finalized", 2, T0, T0, T0 + timedelta(hours=1))],
        "roster": [(24,)],
        "attendance": [("present", "ml", "recognized", "-", 20), ("absent", "ml", "not_recognized", "not_seen", 3),
                       ("absent", "ml", "not_recognized", "look_alike", 1)],
        "observations": [("not_seen", 3, 0, 0.0, 0), ("look_alike", 1, 12, 12.0, 12)],
        "closeness": [(0.1, 2), (0.4, 2)],
        "captures": [(capture, "failed", "phone", created, created, 1, 11_000_000, "uploaded", {})],
        "jobs": [("00000001-0000-4000-8000-000000000000", capture, "recognition", "failed", "failed", 3, "WORKER_ERROR", created, created)],
    }
    conn = FakeConnection(data)
    db = report.Database(connect=lambda url: conn)
    assert db.conn is conn
    events, total = report.read_events(healthy())
    text = report.make_report(events, total, SESSION, 10**9, db, None, "test")
    assert "status **finalized**" in text and "roster 24" in text
    assert "present 20" in text and "absent 4" in text
    assert "final per-student state in the database: not_seen 3, look_alike 1" in text or "look_alike 1" in text
    assert "Capture cccccccc is 'failed' in the database" in text
    assert "job 00000001 is 'failed' in the database (stage failed, error WORKER_ERROR)" in text
    assert "1 student(s) look too similar to another student" in text
    assert "best similarity of non-recognised students" in text
    assert all(sql.lstrip().startswith(("SELECT", "SET", "SHOW")) for sql in conn.executed)
    assert re.search(r"-\s*\d", text)  # sanity: tables rendered
