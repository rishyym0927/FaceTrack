"""scripts/logs: follow one session, job or request through mixed API and worker output."""

import json
import subprocess
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[3] / "scripts" / "logs"
SESSION = "11111111-1111-1111-1111-111111111111"
JOB = "22222222-2222-2222-2222-222222222222"


def line(service, event, **fields):
    return json.dumps({"ts": "2026-11-21T10:00:00.000+00:00", "service": service, "event": event, **fields})


LOG = "\n".join(
    [
        "Attaching noise that is not JSON",
        "INFO:     " + line("api", "request", request_id="aaaaaaaa-1", session_id=SESSION, status=200),
        "WARNING:  " + line("api", "request", request_id="bbbbbbbb-2", session_id=SESSION, status=409, code="SESSION_STATE"),
        "INFO:     " + line("api", "request", request_id="cccccccc-3", session_id="other", status=200),
        line("api", "database_error", level="error", error="OperationalError"),
        line("api", "client_event", level="info", kind="api_error", http_status=503),
        line("worker", "job_start", level="info", job_id=JOB),
        line("worker", "worker_error", level="error", job_id=JOB, stage="download"),
        line("worker", "resources", level="info", cpu_percent=41.5, mem_available_mb=5000),
        line("worker", "resources", level="info", cpu_percent=88.0, mem_available_mb=900),
        # as Celery prints worker lines, and as the persistent capture stores any container's
        "[2026-11-21 15:42:02,730: WARNING/MainProcess] "
        + line("worker", "download_done", level="info", job_id=JOB, bytes=10896480),
        "facetrack-worker-2 2026-11-21T15:42:03.000000000Z "
        + line("worker", "lease_lost", level="warning", job_id=JOB, reason="api_rejected"),
    ]
)


def run(*args, stdin=LOG):
    result = subprocess.run(
        ["sh", str(SCRIPT), "--stdin", *args], input=stdin, capture_output=True, text=True, timeout=20
    )
    return result.returncode, [json.loads(x) for x in result.stdout.splitlines() if x.strip()], result.stderr


def test_a_session_id_follows_only_that_session():
    code, rows, _ = run(SESSION)
    assert code == 0 and [r["request_id"] for r in rows] == ["aaaaaaaa-1", "bbbbbbbb-2"]


def test_a_request_id_prefix_finds_one_failure():
    _, rows, _ = run("bbbbbbbb")
    assert [r["code"] for r in rows] == ["SESSION_STATE"]


def test_a_job_id_follows_the_worker_stages():
    _, rows, _ = run(JOB)
    assert [r["event"] for r in rows] == [
        "job_start", "worker_error", "download_done", "lease_lost",
    ]


def test_errors_only():
    _, rows, _ = run("--errors")
    assert {r["event"] for r in rows} == {
        "request", "worker_error", "database_error", "lease_lost",
    }
    # a status reported by an app is not a server error
    assert all(r.get("level") in ("error", "warning") or r.get("status", 0) >= 400 for r in rows)


def test_resources_shows_recent_readings():
    _, rows, _ = run("--resources")
    assert [r["cpu_percent"] for r in rows] == [41.5, 88.0]


def test_unsafe_input_is_refused():
    code, _, err = run("a; rm -rf /")
    assert code == 2 and "letters, digits and dashes" in err
    code, _, err = run("--since", "1h; echo", SESSION)
    assert code == 2 and "Invalid --since" in err


def test_no_arguments_prints_usage():
    code, rows, _ = run()
    assert code == 2 and rows == []


def test_vm_mode_reads_the_persistent_files_and_cuts_by_time():
    """The command run on the server prefers /var/log/facetrack and falls back to Docker."""
    import re

    result = subprocess.run(
        ["sh", "-c", f"sed -n '/^vm_command()/,/^}}/p' {SCRIPT}"], capture_output=True, text=True
    )
    body = result.stdout
    assert "/var/log/facetrack/*.log" in body and "zcat" in body
    assert "docker compose logs" in body  # fallback while the capture is not installed
    assert re.search(r"claim.*204", body)  # idle polls are dropped on the server
