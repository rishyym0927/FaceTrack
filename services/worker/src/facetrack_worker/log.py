"""Structured, privacy-safe event logging for the worker and agent.

One JSON object per line on stdout (collected by Docker): ``ts``, ``level``, ``service``,
``event`` and correlation ids such as ``job_id``, plus counts and timings. Never logged:
names, emails, enrolment numbers, tokens, signed URLs, embeddings, frames or per-student scores.
Fields are filtered here so a careless caller cannot leak them.
"""

import json
import math
import re
import shutil
import time
from datetime import UTC, datetime
from pathlib import Path

SERVICE = "worker"
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
SENSITIVE_VALUE = re.compile(
    r"(eyJ[A-Za-z0-9_-]{10,}|[\w.+-]+@[\w-]+\.[\w.-]+|https?://\S+|"
    r"(?:token|signature|apikey|password)=)",
    re.IGNORECASE,
)
MAX_TEXT = 160


def clean(fields):
    out = {}
    for key, value in fields.items():
        lowered = key.lower()
        if value is None or any(part in lowered for part in BANNED_PARTS):
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
                if (isinstance(v, bool | int) or (isinstance(v, float) and math.isfinite(v)))
                and not any(p in str(k).lower() for p in BANNED_PARTS)
            }
        elif isinstance(value, list | tuple):
            continue  # lists are never logged: they could carry per-student values
        else:
            text = str(value)
            out[key] = "[redacted]" if SENSITIVE_VALUE.search(text) else text[:MAX_TEXT]
    return out


def record(name, level="info", **fields):
    return {
        "ts": datetime.now(UTC).isoformat(timespec="milliseconds"),
        "level": level,
        "service": SERVICE,
        "event": name,
        **clean(fields),
    }


def event(name, level="info", **fields):
    print(json.dumps(record(name, level, **fields), separators=(",", ":")), flush=True)


_cpu = {"busy": None, "total": None}


def _cpu_percent():
    """CPU use since the previous call, from /proc/stat; None when unavailable."""
    try:
        parts = Path("/proc/stat").read_text().splitlines()[0].split()[1:]
        values = [int(x) for x in parts]
    except (OSError, ValueError, IndexError):
        return None
    total, idle = sum(values), values[3] + (values[4] if len(values) > 4 else 0)
    busy = total - idle
    previous_busy, previous_total = _cpu["busy"], _cpu["total"]
    _cpu["busy"], _cpu["total"] = busy, total
    if previous_total is None or total == previous_total:
        return None
    return round(100 * (busy - previous_busy) / (total - previous_total), 1)


def resources(path="/"):
    """Host CPU, load, memory and disk, read from /proc without extra dependencies."""
    fields = {}
    try:
        load = Path("/proc/loadavg").read_text().split()
        fields.update(load1=float(load[0]), load5=float(load[1]))
        info = {
            line.split(":")[0]: int(line.split()[1])
            for line in Path("/proc/meminfo").read_text().splitlines()
        }
        fields.update(
            mem_total_mb=info["MemTotal"] // 1024, mem_available_mb=info["MemAvailable"] // 1024
        )
    except (OSError, ValueError, KeyError, IndexError):
        pass
    cpu = _cpu_percent()
    if cpu is not None:
        fields["cpu_percent"] = cpu
    try:
        usage = shutil.disk_usage(path)
        fields.update(disk_free_gb=round(usage.free / 1e9, 1), disk_used_percent=round(100 * usage.used / usage.total, 1))
    except OSError:
        pass
    return fields


def elapsed_ms(start):
    return round((time.monotonic() - start) * 1000)
