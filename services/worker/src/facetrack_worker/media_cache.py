"""Per-process memo for facts about one local file (its probe result, its SHA-256).

A job's child process used to run ffprobe twice (rotation check, then the dense sampler) and hash
the same 10-25 MB file four times (leased-input check, source hash, processed hash, report hash).
The key includes size and modification time, so a changed file is never served from the memo.
"""

from pathlib import Path

_MEMO = {}
_LIMIT = 16


def once(name, path, compute):
    path = Path(path)
    stat = path.stat()
    key = (name, str(path), stat.st_size, stat.st_mtime_ns)
    if key not in _MEMO:
        if len(_MEMO) >= _LIMIT:
            _MEMO.clear()
        _MEMO[key] = compute()
    return _MEMO[key]


def sha256(path):
    from facetrack_ml.config import digest

    return once("sha256", path, lambda: digest(Path(path)))
