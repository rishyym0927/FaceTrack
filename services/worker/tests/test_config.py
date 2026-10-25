import os
import subprocess
import sys


def run_validation(tmp_path, *, container_network, api="http://api:8000", redis="redis://redis:6379/0"):
    manifest = tmp_path / "manifest.json"
    profile = tmp_path / "profile.json"
    manifest.write_text("{}")
    profile.write_text("{}")
    env = {
        **os.environ,
        "API_BASE_URL": api,
        "WORKER_TOKEN": "ftw_test-only",
        "REDIS_URL": redis,
        "MANIFEST_PATH": str(manifest),
        "PROFILE_PATH": str(profile),
        "FACETRACK_CONTAINER_NETWORK": "1" if container_network else "0",
    }
    return subprocess.run(
        [sys.executable, "-c", "from facetrack_worker.config import validate; validate()"],
        env=env,
        capture_output=True,
        text=True,
    )


def test_compose_service_hosts_require_explicit_container_mode(tmp_path):
    denied = run_validation(tmp_path, container_network=False)
    assert denied.returncode != 0
    assert "Worker API must use HTTPS or local loopback" in denied.stderr

    allowed = run_validation(tmp_path, container_network=True)
    assert allowed.returncode == 0, allowed.stderr


def test_container_mode_does_not_allow_arbitrary_plaintext_hosts(tmp_path):
    result = run_validation(
        tmp_path,
        container_network=True,
        api="http://example.invalid:8000",
        redis="redis://example.invalid:6379/0",
    )
    assert result.returncode != 0
    assert "Worker API must use HTTPS or local loopback" in result.stderr
