"""Structured, privacy-safe event logging.

Every event is one JSON line: ``ts``, ``service``, ``event`` plus a few correlation ids
(``request_id``, ``session_id``, ``capture_id``, ``job_id``) and counts or timings. That is
enough to follow one class end to end with ``scripts/logs``.

Never logged: names, emails, enrolment numbers, tokens, signed URLs, embeddings, frames or
per-student scores. Fields are filtered here as a last line of defence, so a careless caller
cannot leak them.
"""

from __future__ import annotations

import json
import logging
import math
import re
import time
import traceback
from collections import deque
from datetime import UTC, datetime

logger = logging.getLogger("uvicorn.error.facetrack")

# Any field whose name contains one of these is dropped.
BANNED_PARTS = (
    "password",
    "secret",
    "token",
    "authorization",
    "cookie",
    "email",
    "name",
    "enrollment",
    "enrolment",
    "employee",
    "phone",
    "signature",
    "url",
    "vector",
    "embedding",
    "template",
    "similarity",
    "apikey",
    "api_key",
    "credential",
)
# Values that look like secrets are replaced even under an innocent field name.
SENSITIVE_VALUE = re.compile(
    r"(eyJ[A-Za-z0-9_-]{10,}|[\w.+-]+@[\w-]+\.[\w.-]+|https?://\S+|"
    r"(?:token|signature|apikey|password)=)",
    re.IGNORECASE,
)
MAX_TEXT = 160


def clean(fields: dict) -> dict:
    out = {}
    for key, value in fields.items():
        lowered = key.lower()
        if value is None or (not lowered.endswith('_ms') and any(part in lowered for part in BANNED_PARTS)):
            continue
        if isinstance(value, bool | int):
            out[key] = value
        elif isinstance(value, float):
            if math.isfinite(value):  # NaN and Infinity are not valid JSON
                out[key] = value
        elif isinstance(value, dict):
            out[key] = {
                str(k)[:40]: v
                for k, v in value.items()
                if isinstance(v, bool | int)
                or (isinstance(v, float) and math.isfinite(v))
                if (str(k).lower().endswith('_ms') or not any(p in str(k).lower() for p in BANNED_PARTS))
            }
        elif isinstance(value, list | tuple):
            continue  # lists are never logged: they could carry per-student values
        else:
            text = str(value)
            out[key] = "[redacted]" if SENSITIVE_VALUE.search(text) else text[:MAX_TEXT]
    return out


def record(name: str, level: int = logging.INFO, **fields) -> dict:
    return {
        "ts": datetime.now(UTC).isoformat(timespec="milliseconds"),
        "level": logging.getLevelName(level).lower(),
        "service": "api",
        "event": name,
        **clean(fields),
    }


def event(name: str, *, level: int = logging.INFO, **fields) -> None:
    logger.log(level, json.dumps(record(name, level, **fields), separators=(",", ":")))


SESSION_ROUTE = re.compile(r"/sessions/\{(\w+)\}")
CAPTURE_ROUTE = re.compile(r"/captures/\{(\w+)\}")
JOB_ROUTE = re.compile(r"/jobs/\{(\w+)\}")


def correlation(route_path: str, params: dict) -> dict:
    """Session, capture and job ids taken from the matched route's path parameters."""
    ids = {}
    for label, pattern in (
        ("session_id", SESSION_ROUTE),
        ("capture_id", CAPTURE_ROUTE),
        ("job_id", JOB_ROUTE),
    ):
        found = pattern.search(route_path or "")
        if found and found.group(1) in params:
            ids[label] = str(params[found.group(1)])
    return ids


class Budget:
    """Small per-key sliding-window allowance (in process; the API runs one process)."""

    def __init__(self, limit: int, seconds: int, clock=time.monotonic):
        self.limit, self.seconds, self.clock = limit, seconds, clock
        self.seen: dict[str, deque] = {}

    def take(self, key: str, count: int = 1) -> bool:
        now = self.clock()
        window = self.seen.setdefault(key, deque())
        while window and now - window[0] > self.seconds:
            window.popleft()
        if len(window) + count > self.limit:
            return False
        window.extend([now] * count)
        if len(self.seen) > 5000:  # keep memory bounded
            for stale in [k for k, w in self.seen.items() if not w or now - w[-1] > self.seconds]:
                del self.seen[stale]
        return True


class RedactUvicornLogs(logging.Filter):
    """Keep uvicorn's own log lines (notably re-raised exceptions) free of personal data.

    Starlette re-raises unhandled exceptions after our handler answered, so uvicorn logs the
    full traceback, whose exception text can carry SQL parameters or request values. Records
    with an exception are reduced to the exception type and code location; other text has
    anything secret-looking replaced. Our own structured events use a child logger and are
    already filtered by ``clean``.
    """

    def filter(self, record: logging.LogRecord) -> bool:
        if record.exc_info and record.exc_info[1] is not None:
            error = record.exc_info[1]
            frames = traceback.extract_tb(record.exc_info[2]) if record.exc_info[2] else []
            where = f"{frames[-1].filename.rsplit('/', 1)[-1]}:{frames[-1].lineno}" if frames else "?"
            record.msg, record.args = f"Unhandled {type(error).__name__} at {where}", None
            record.exc_info = record.exc_text = None
            record.stack_info = None
            return True
        try:
            message = record.getMessage()
        except Exception:
            message = str(record.msg)
        if SENSITIVE_VALUE.search(message):
            message = SENSITIVE_VALUE.sub("[redacted]", message)
        record.msg, record.args = message, None
        return True


def install_redaction() -> None:
    """Attach the filter to uvicorn's loggers once."""
    for name in ("uvicorn", "uvicorn.error"):
        target = logging.getLogger(name)
        if not any(isinstance(f, RedactUvicornLogs) for f in target.filters):
            target.addFilter(RedactUvicornLogs())
