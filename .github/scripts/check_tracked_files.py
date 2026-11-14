"""Fail CI if Git tracks private FaceTrack artifacts or obvious credential values."""

import re
import subprocess
from pathlib import Path


FORBIDDEN_SUFFIXES = {
    ".jks", ".keystore", ".p12", ".pfx", ".pem", ".key", ".enc",
    ".onnx", ".npy", ".npz", ".mp4", ".webm", ".mov", ".avi",
}
SECRET_MARKERS = (
    re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    re.compile(rb"sb_secret_[A-Za-z0-9]{12,}"),
)


def main() -> int:
    paths = subprocess.check_output(["git", "ls-files", "-z"]).split(b"\0")
    failures = []
    for raw in paths:
        if not raw:
            continue
        path = Path(raw.decode())
        if path.name == ".env" or (path.name.startswith(".env.") and path.name != ".env.example"):
            failures.append(f"tracked private configuration: {path}")
            continue
        if path.suffix.lower() in FORBIDDEN_SUFFIXES or path.name == "key.properties":
            failures.append(f"tracked private artifact: {path}")
            continue
        if not path.is_file() or path.stat().st_size > 1_000_000:
            continue
        content = path.read_bytes()
        if any(marker.search(content) for marker in SECRET_MARKERS):
            failures.append(f"possible credential value in: {path}")
    for failure in failures:
        print(failure)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
