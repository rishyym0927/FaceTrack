"""deploy/azure/log_capture.py: logs survive container recreation, nothing is stored twice."""

import importlib.util
import json
import os
import stat
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location("log_capture", ROOT / "deploy/azure/log_capture.py")
log_capture = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(log_capture)

# A stand-in `docker`: `ps -a` lists $SHIM/containers.tsv, `logs` prints $SHIM/<id>.log from the
# --since timestamp on (inclusive, like docker), `inspect` says nothing is running.
SHIM = r"""#!/usr/bin/env python3
import os, sys
shim = os.environ["SHIM"]
args = sys.argv[1:]
if args[0] == "ps":
    sys.stdout.write(open(f"{shim}/containers.tsv").read())
elif args[0] == "inspect":
    print("false")
elif args[0] == "logs":
    since = args[args.index("--since") + 1] if "--since" in args else ""
    for line in open(f"{shim}/{args[-1]}.log").read().splitlines():
        if not since or line.split(" ")[0] >= since:
            print(line)
"""


def line(second, event="probe", **fields):
    body = json.dumps({"ts": f"2026-11-21T10:00:{second:02d}.000+00:00", "event": event, **fields})
    return f"2026-11-21T10:00:{second:02d}.000000000Z {body}"


def setup(tmp_path, monkeypatch):
    shim = tmp_path / "shim"
    shim.mkdir()
    docker = shim / "docker"
    docker.write_text(SHIM)
    docker.chmod(docker.stat().st_mode | stat.S_IEXEC)
    monkeypatch.setenv("SHIM", str(shim))
    monkeypatch.setenv("PATH", f"{shim}{os.pathsep}{os.environ['PATH']}")
    return shim


def run(tmp_path, monkeypatch=None):
    capture = log_capture.Capture(
        tmp_path / "out", tmp_path / "state.json", docker="docker", poll=0.1, follow=False
    )
    capture.out_dir.mkdir(exist_ok=True)
    capture.poll_once()
    for thread in capture.threads.values():
        thread.join(timeout=20)
    capture.save_state()
    return capture


def stored(tmp_path, service):
    path = tmp_path / "out" / f"{service}.log"
    return path.read_text().splitlines() if path.exists() else []


def test_lines_are_stored_per_service_with_the_container_name(tmp_path, monkeypatch):
    shim = setup(tmp_path, monkeypatch)
    (shim / "containers.tsv").write_text("aaa\tfacetrack-api-1\tapi\nbbb\tfacetrack-worker-2\tworker\n")
    (shim / "aaa.log").write_text("\n".join([line(1), line(2, "client_event")]) + "\n")
    (shim / "bbb.log").write_text(line(3, "job_start") + "\n")
    run(tmp_path)
    api = stored(tmp_path, "api")
    assert [row.split(" ")[0] for row in api] == ["facetrack-api-1"] * 2
    assert api[1].split(" ", 2)[1] == "2026-11-21T10:00:02.000000000Z"
    assert json.loads(api[1].split(" ", 2)[2])["event"] == "client_event"
    assert stored(tmp_path, "worker")[0].startswith("facetrack-worker-2 ")


def test_a_second_run_stores_only_what_is_new(tmp_path, monkeypatch):
    shim = setup(tmp_path, monkeypatch)
    (shim / "containers.tsv").write_text("aaa\tfacetrack-api-1\tapi\n")
    (shim / "aaa.log").write_text(line(1) + "\n" + line(2) + "\n")
    run(tmp_path)
    with open(shim / "aaa.log", "a") as handle:
        handle.write(line(3) + "\n")
    run(tmp_path)  # the stand-in re-sends the last stored line, as docker's inclusive --since does
    assert len(stored(tmp_path, "api")) == 3


def test_logs_of_a_replaced_container_are_kept_next_to_the_new_ones(tmp_path, monkeypatch):
    """A deploy recreates every container under a new id; the old log file is deleted by Docker."""
    shim = setup(tmp_path, monkeypatch)
    (shim / "containers.tsv").write_text("old1\tfacetrack-worker-1\tworker\n")
    (shim / "old1.log").write_text(line(1, "job_done") + "\n")
    run(tmp_path)
    # deploy: the old container and its log are gone, a new one exists
    (shim / "containers.tsv").write_text("new2\tfacetrack-worker-1\tworker\n")
    (shim / "old1.log").unlink()
    (shim / "new2.log").write_text(line(9, "job_start") + "\n")
    run(tmp_path)
    events = [json.loads(row.split(" ", 2)[2])["event"] for row in stored(tmp_path, "worker")]
    assert events == ["job_done", "job_start"]
    state = json.loads((tmp_path / "state.json").read_text())
    assert list(state) == ["new2"]  # the vanished container is forgotten


def test_it_only_ever_reads(tmp_path, monkeypatch):
    shim = setup(tmp_path, monkeypatch)
    (shim / "containers.tsv").write_text("aaa\tfacetrack-api-1\tapi\n")
    (shim / "aaa.log").write_text(line(1) + "\n")
    calls = tmp_path / "calls.txt"
    docker = shim / "docker"
    docker.write_text(docker.read_text().replace("args = sys.argv[1:]", f"args = sys.argv[1:]\nopen({str(calls)!r}, 'a').write(args[0] + '\\n')"))
    run(tmp_path)
    assert set(calls.read_text().split()) <= {"ps", "logs", "inspect"}
    source = (ROOT / "deploy/azure/log_capture.py").read_text()
    for verb in ("restart", "stop", "kill", "rm", "exec", "compose", "update"):
        assert f'"{verb}"' not in source


def test_a_full_disk_pauses_capture_instead_of_filling_it(tmp_path, monkeypatch):
    shim = setup(tmp_path, monkeypatch)
    (shim / "containers.tsv").write_text("aaa\tfacetrack-api-1\tapi\n")
    (shim / "aaa.log").write_text(line(1) + "\n")
    monkeypatch.setattr(log_capture, "MIN_FREE_BYTES", 10**18)
    run(tmp_path)
    assert stored(tmp_path, "api") == []


def test_timestamps_order_like_time_even_with_trimmed_fractions():
    key = log_capture.stamp_key
    assert key("2026-11-21T10:00:01.5Z") < key("2026-11-21T10:00:01.500000001Z")
    assert key("2026-11-21T10:00:01Z") < key("2026-11-21T10:00:01.000000001Z")
    assert key("2026-11-21T10:00:02Z") > key("2026-11-21T10:00:01.999999999Z")


def test_the_installer_and_unit_are_valid_shell():
    script = ROOT / "deploy/azure/install_log_capture.sh"
    assert subprocess.run(["sh", "-n", str(script)]).returncode == 0
    text = script.read_text()
    code = "\n".join(row for row in text.splitlines() if not row.lstrip().startswith("#"))
    # idempotent and read-only with respect to the app
    for forbidden in ("docker compose", "docker restart", "docker stop", "/opt/facetrack"):
        assert forbidden not in code, forbidden
    assert "rotate 14" in text and "maxsize 200M" in text and "copytruncate" in text
    assert sys.executable
