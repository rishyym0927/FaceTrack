"""Activate two staged Flutter builds through one shared symlink."""

import fcntl
import hashlib
import os
from pathlib import Path
import shutil
import sys
import tempfile
from urllib.request import urlopen

APPS = ("teacher", "student")
ASSETS = ("index.html", "main.dart.js")


def replace_link(path, target):
    with tempfile.TemporaryDirectory(dir=path.parent) as temporary:
        link = Path(temporary) / "link"
        link.symlink_to(target)
        os.replace(link, path)


def prepare_legacy_layout(root):
    """Move the existing live directories behind the shared pointer once."""
    current = root / "web-current"
    aliases = {app: root / app for app in APPS}
    if not current.is_symlink():
        if not all(path.is_dir() and not path.is_symlink() for path in aliases.values()):
            raise ValueError("Expected existing Teacher and Student web directories")
        legacy = Path(tempfile.mkdtemp(prefix="release-legacy-", dir=root))
        legacy.chmod(0o755)
        for app, path in aliases.items():
            shutil.copytree(path, legacy / app)
        replace_link(current, legacy.name)

    # The current pointer initially serves the exact same files as the legacy
    # directories. This also resumes a partially completed first migration.
    for app, path in aliases.items():
        target = f"web-current/{app}"
        if path.is_symlink() and os.readlink(path) == target:
            continue
        if not path.is_dir() or path.is_symlink():
            raise ValueError(f"Unexpected live directory: {path}")
        with tempfile.TemporaryDirectory(dir=root) as temporary:
            backup = Path(temporary) / app
            path.rename(backup)
            try:
                replace_link(path, target)
            except BaseException:
                backup.rename(path)
                raise


def digest(stream):
    result = hashlib.sha256()
    for chunk in iter(lambda: stream.read(65536), b""):
        result.update(chunk)
    return result.digest()


def smoke(base_url, expected, release):
    for (app, asset), checksum in expected.items():
        name = "" if asset == "index.html" else asset
        with urlopen(f"{base_url}/{app}/{name}?release={release}", timeout=15) as response:
            if response.status != 200 or digest(response) != checksum:
                raise RuntimeError(f"{app}/{asset} did not serve the staged release")


def activate(root, stage, base_url):
    if stage.parent != root or not stage.name.startswith("release-") or stage.is_symlink():
        raise ValueError("Expected a staged release directory")
    expected = {}
    for app in APPS:
        for asset in ASSETS:
            with (stage / app / asset).open("rb") as stream:
                expected[app, asset] = digest(stream)

    with (root / ".web-release.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        prepare_legacy_layout(root)
        current = root / "web-current"
        previous = os.readlink(current)
        replace_link(current, stage.name)
        try:
            smoke(base_url, expected, stage.name)
        except BaseException:
            replace_link(current, previous)
            raise


if __name__ == "__main__":
    root, stage, base_url = sys.argv[1:]
    activate(Path(root), Path(stage), base_url)
