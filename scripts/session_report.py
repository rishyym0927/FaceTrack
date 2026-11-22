#!/usr/bin/env python3
"""One Markdown report about a class: what the app did, what the server did, what the model saw.

    scripts/session-report <session-id>          one class (add --vm to read the Azure VM)
    scripts/session-report latest                the most recent class in the logs
    scripts/session-report --since 3h            every class active in the last 3 hours
    some-command | scripts/session-report --stdin <session-id|latest>

It reads the structured JSON logs (docs/DEPLOY_AZURE.md "Reading the logs") from stdin, files,
a directory of captured logs, local Docker, or the VM over ssh, and, read-only, the hosted
database for ids and aggregate counts. It never prints names, emails, enrolment numbers or any
score of a named student: the database queries select only counts, statuses and ids of captures
and jobs. Standard library only (psycopg is used when present, for the database part).
"""

import argparse
import gzip
import json
import os
import re
import statistics
import subprocess
import sys
from collections import Counter, defaultdict
from datetime import UTC, datetime, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
UUID = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
SINCE = re.compile(r"^(\d+)([smhd])$")
JSON_START = re.compile(r'\{"')
NOISE_ROUTES = ("/health/ready", "/health/live", "/health")
SLOW_REQUEST_MS = 3000
SLOW_QUEUE_S = 30
SLOW_DOWNLOAD_MBPS = 8.0
REASONS = ("recognized", "not_seen", "look_alike", "weak_match", "seen_too_briefly")
GATE_ADVICE = {
    "small": "faces were too small in the frame (camera too far or zoomed out)",
    "blur": "faces were blurred (motion, focus or low light)",
    "edge": "faces were cut off at the edge of the picture",
    "landmarks": "faces were turned away or covered so the eyes and mouth were not found",
    "brightness": "the picture was too dark or too bright",
}


# ----------------------------------------------------------------------------------------------
# parsing
# ----------------------------------------------------------------------------------------------
def parse_time(text):
    if not isinstance(text, str):
        return None
    try:
        value = datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return None
    return value if value.tzinfo else value.replace(tzinfo=UTC)


class Event:
    __slots__ = ("ts", "service", "name", "d", "container")

    def __init__(self, ts, service, name, d, container=None):
        self.ts, self.service, self.name, self.d, self.container = ts, service, name, d, container

    def get(self, key, default=None):
        return self.d.get(key, default)

    @property
    def at(self):
        """When it happened: client events carry their own time, the rest were logged as it happened."""
        return parse_time(self.d.get("event_at")) or self.ts


def parse_line(line):
    """The event in a log line, or None. Anything before the first ``{"`` is a prefix."""
    found = JSON_START.search(line)
    if not found:
        return None
    text = line[found.start():].rstrip()
    try:
        data = json.loads(text)
    except ValueError:
        return None
    if not isinstance(data, dict) or "event" not in data:
        return None
    ts = parse_time(data.get("ts"))
    if ts is None:
        return None
    prefix = line[: found.start()]
    container = re.search(r"\b(facetrack-[\w.-]+)", prefix)
    return Event(ts, data.get("service", "?"), data["event"], data, container.group(1) if container else None), text


def read_events(lines):
    events, seen, total = [], set(), 0
    for line in lines:
        total += 1
        parsed = parse_line(line)
        if not parsed:
            continue
        event, text = parsed
        # idle job polling and health checks are most of the volume and tell nothing
        if event.name == "request" and (
            event.get("route") in NOISE_ROUTES
            or (event.get("route") == "/internal/v1/jobs/claim" and event.get("status") == 204)
        ):
            continue
        key = (event.container, text)
        if key in seen:  # the same line captured twice (restart of the capture, or two sources)
            continue
        seen.add(key)
        events.append(event)
    events.sort(key=lambda e: e.ts)
    return events, total


def open_text(path):
    path = Path(path)
    if path.suffix == ".gz":
        return gzip.open(path, "rt", encoding="utf-8", errors="replace")
    return open(path, encoding="utf-8", errors="replace")


def lines_from_dir(directory):
    for path in sorted(Path(directory).iterdir()):
        if path.is_file() and (".log" in path.name):
            with open_text(path) as handle:
                yield from handle


def lines_from_script(vm, since):
    command = ["sh", str(ROOT / "scripts" / "logs"), "--all", "--since", since]
    if vm:
        command.append("--vm")
    result = subprocess.run(command, capture_output=True, text=True, timeout=600)
    if result.returncode != 0:
        raise SystemExit(f"scripts/logs failed ({result.returncode}): {result.stderr.strip()[:300]}")
    return result.stdout.splitlines()


# ----------------------------------------------------------------------------------------------
# database (read only, aggregates and ids)
# ----------------------------------------------------------------------------------------------
# The statements below are the only ones the report runs. They name no personal column: no
# student id, name snapshot, email or enrolment number, and no per-student score.
SQL = {
    "session": "SELECT status, attendance_revision, created_at, starts_at, ends_at FROM app.sessions WHERE id=%s",
    "roster": "SELECT count(*) FROM app.session_roster WHERE session_id=%s",
    "attendance": """SELECT status, source, coalesce(assessment_code,'-'),
        coalesce(evidence_summary->>'reason','-'), count(*)
        FROM app.attendance_records WHERE session_id=%s GROUP BY 1,2,3,4 ORDER BY 5 DESC""",
    "observations": """SELECT coalesce(evidence_summary->>'reason','-') AS reason, count(*),
        min((evidence_summary->>'observations')::int),
        percentile_cont(0.5) WITHIN GROUP (ORDER BY (evidence_summary->>'observations')::int),
        max((evidence_summary->>'observations')::int)
        FROM app.attendance_records
        WHERE session_id=%s AND evidence_summary ? 'observations' AND evidence_summary->>'reason' IS NOT NULL
        GROUP BY 1""",
    "closeness": """SELECT floor(((evidence_summary->>'best_similarity')::float8 + 1) * 10) / 10 - 1 AS bucket, count(*)
        FROM app.attendance_records
        WHERE session_id=%s AND evidence_summary->>'best_similarity' IS NOT NULL
        AND coalesce(evidence_summary->>'reason','') <> 'recognized'
        GROUP BY 1 ORDER BY 1""",
    "captures": """SELECT c.id, c.status, c.source_type, c.created_at, c.recorded_at, c.generation,
        m.byte_size, m.status, c.quality_json - 'processed_sha256' - 'source_sha256'
        FROM app.captures c JOIN app.media_assets m ON m.institute_id=c.institute_id AND m.id=c.asset_id
        WHERE c.session_id=%s ORDER BY c.created_at""",
    "jobs": """SELECT j.id, j.capture_id, j.kind, j.state, j.stage, j.attempts, j.error_code,
        j.created_at, j.updated_at
        FROM app.jobs j JOIN app.captures c ON c.institute_id=j.institute_id AND c.id=j.capture_id
        WHERE c.session_id=%s ORDER BY j.created_at""",
    "recent": """SELECT DISTINCT c.session_id, max(c.created_at) OVER (PARTITION BY c.session_id) AS last
        FROM app.captures c WHERE c.created_at >= %s ORDER BY last DESC""",
}


def database_url():
    candidates = [os.environ.get("MIGRATION_DATABASE_URL")]
    env = ROOT / "services" / "api" / ".env"
    if env.exists():
        for row in env.read_text().splitlines():
            if row.startswith("MIGRATION_DATABASE_URL="):
                candidates.append(row.split("=", 1)[1])
    for value in candidates:
        if value:
            value = value.strip().strip("'\"")
            return value.replace("postgresql+psycopg://", "postgresql://")
    return None


class Database:
    """Read-only connection. Errors are reported by class name only: never the message, which
    can contain the connection string."""

    def __init__(self, connect=None):
        self.error = None
        self.conn = None
        try:
            url = database_url()
            if not url:
                raise LookupError("no MIGRATION_DATABASE_URL")
            if connect is None:
                import psycopg  # noqa: PLC0415

                connect = lambda u: psycopg.connect(u, connect_timeout=15, autocommit=False)  # noqa: E731
            self.conn = connect(url)
            try:
                self.conn.read_only = True
            except AttributeError:
                pass
            cur = self.conn.cursor()
            cur.execute("SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY")
            cur.execute("SET statement_timeout = '20s'")
            cur.execute("SHOW transaction_read_only")
            if (cur.fetchone() or ("off",))[0] != "on":
                raise PermissionError("connection is not read only")
        except Exception as error:  # noqa: BLE001
            self.error = type(error).__name__
            if self.conn is not None:
                try:
                    self.conn.close()
                except Exception:  # noqa: BLE001
                    pass
            self.conn = None

    def rows(self, name, *params):
        cur = self.conn.cursor()
        cur.execute(SQL[name], params)
        return cur.fetchall()

    def close(self):
        if self.conn is not None:
            try:
                self.conn.rollback()
                self.conn.close()
            except Exception:  # noqa: BLE001
                pass


def load_session_db(db, sid):
    """Aggregates and ids for one session; ``{"error": ...}`` if anything fails."""
    try:
        head = db.rows("session", sid)
        if not head:
            return {"missing": True}
        status, revision, created, starts, ends = head[0]
        out = {
            "status": status, "revision": revision, "created": created, "starts": starts, "ends": ends,
            "roster": db.rows("roster", sid)[0][0],
            "attendance": [
                {"status": r[0], "source": r[1], "code": r[2], "reason": r[3], "count": r[4]}
                for r in db.rows("attendance", sid)
            ],
            "observations": {
                r[0]: {"count": r[1], "min": r[2], "median": float(r[3]) if r[3] is not None else None, "max": r[4]}
                for r in db.rows("observations", sid)
            },
            "closeness": [(float(r[0]), r[1]) for r in db.rows("closeness", sid)],
            "captures": [
                {
                    "id": str(r[0]), "status": r[1], "source": r[2], "created": r[3], "recorded": r[4],
                    "generation": r[5], "bytes": r[6], "media": r[7], "quality": r[8] or {},
                }
                for r in db.rows("captures", sid)
            ],
            "jobs": [
                {
                    "id": str(r[0]), "capture": str(r[1]), "kind": r[2], "state": r[3], "stage": r[4],
                    "attempts": r[5], "error": r[6], "created": r[7], "updated": r[8],
                }
                for r in db.rows("jobs", sid)
            ],
        }
        db.conn.rollback()
        return out
    except Exception as error:  # noqa: BLE001
        try:
            db.conn.rollback()
        except Exception:  # noqa: BLE001
            pass
        return {"error": type(error).__name__}


# ----------------------------------------------------------------------------------------------
# analysis
# ----------------------------------------------------------------------------------------------
def short(identifier):
    return str(identifier)[:8] if identifier else "-"


def clock(ts, date=False):
    if ts is None:
        return "-"
    return ts.astimezone(UTC).strftime("%Y-%m-%d %H:%M:%S" if date else "%H:%M:%S")


def seconds(value, digits=1):
    return "-" if value is None else f"{value:.{digits}f}"


def megabytes(count):
    return "-" if count is None else f"{count / 1e6:.1f}"


class Job:
    def __init__(self, job_id):
        self.id = job_id
        self.kind = None
        self.session = None
        self.capture = None
        self.claimed = None  # when the agent took it (job_dispatched, or API job_claimed)
        self.queue_wait_ms = None
        self.starts = []
        self.download = {}
        self.inference = {}
        self.done_ms = None
        self.done_at = None
        self.complete = {}  # the API's recognition_complete
        self.failures = []  # API or worker job_failed / worker_error
        self.lease_lost = []
        self.db = {}
        self.est_wait = None  # seconds, estimated by pairing uploads with jobs in order


class Analysis:
    def __init__(self, events, db=None):
        self.events = events
        self.db = db
        self.jobs = {}
        self.capture_session = {}
        self.job_session = {}
        self.index()

    def job(self, job_id):
        if job_id not in self.jobs:
            self.jobs[job_id] = Job(job_id)
        return self.jobs[job_id]

    def index(self):
        for e in self.events:
            jid, sid, cid = e.get("job_id"), e.get("session_id"), e.get("capture_id")
            if cid and sid:
                self.capture_session[cid] = sid
            if jid and sid:
                self.job_session[jid] = sid
            if jid and cid:
                self.job(jid).capture = cid
        for e in self.events:
            jid = e.get("job_id")
            if not jid:
                continue
            job = self.job(jid)
            n = e.name
            if n in ("job_dispatched", "job_claimed"):
                job.claimed = job.claimed or e.ts
                if e.get("queue_wait_ms") is not None:
                    job.queue_wait_ms = e.get("queue_wait_ms")
            elif n == "job_start":
                job.starts.append(e.ts)
            elif n == "download_done":
                job.download = e.d
            elif n == "inference_done":
                job.inference = e.d
                job.kind = e.get("kind") or job.kind
            elif n == "job_done":
                job.done_ms, job.done_at = e.get("total_ms"), e.ts
            elif n == "recognition_complete":
                job.complete = e.d
                job.kind = "recognition"
            elif n in ("job_failed", "worker_error", "inference_timeout", "complete_not_accepted"):
                job.failures.append(e)
                job.kind = job.kind or e.get("kind")
            elif n == "lease_lost":
                job.lease_lost.append(e)
            job.session = job.session or self.job_session.get(jid)

    # which sessions were active -------------------------------------------------------------
    def sessions(self):
        """session id -> last activity, for classes that were scanned or processed."""
        active = {}
        for e in self.events:
            sid = e.get("session_id")
            if not sid:
                continue
            if e.name == "client_event" and e.get("kind") in ("scan_started", "segment_recorded", "upload_done", "scan_stopped"):
                pass
            elif e.name == "recognition_complete":
                pass
            elif e.name == "request" and e.get("method") == "POST" and e.get("status", 0) < 400 and any(
                part in e.get("route", "") for part in ("/captures", "/open", "/close", "/finalize")
            ):
                pass
            else:
                continue
            active[sid] = max(active.get(sid, e.at), e.at)
        for jid, job in self.jobs.items():
            sid = self.job_session.get(jid)
            if sid and job.complete:
                active[sid] = max(active.get(sid, job.done_at or job.claimed), job.done_at or job.claimed)
        return active

    def for_session(self, sid, db_info=None):
        """Everything that belongs to one session, and the time window it occupies."""
        captures = {c for c, s in self.capture_session.items() if s == sid}
        jobs = {j for j, s in self.job_session.items() if s == sid}
        if db_info and "captures" in db_info:
            captures |= {c["id"] for c in db_info["captures"]}
            jobs |= {j["id"] for j in db_info["jobs"]}
        for j in list(jobs):
            if self.jobs.get(j) and self.jobs[j].capture:
                captures.add(self.jobs[j].capture)
        for jid, job in self.jobs.items():  # jobs only known from their capture
            if job.capture in captures:
                jobs.add(jid)
        mine = []
        for e in self.events:
            if (
                e.get("session_id") == sid
                or e.get("job_id") in jobs
                or e.get("capture_id") in captures
            ):
                mine.append(e)
        return mine, captures, jobs


def window(mine, db_info):
    times = [e.at for e in mine]
    if db_info and db_info.get("captures"):
        times += [c["created"] for c in db_info["captures"] if c.get("created")]
    if not times:
        return None, None
    return min(times) - timedelta(seconds=30), max(times) + timedelta(minutes=2)


def in_window(events, start, end):
    return [e for e in events if start <= e.at <= end]


# ----------------------------------------------------------------------------------------------
# markdown
# ----------------------------------------------------------------------------------------------
def table(headers, rows):
    if not rows:
        return "_none_\n"
    out = ["| " + " | ".join(headers) + " |", "|" + "|".join("---" for _ in headers) + "|"]
    for row in rows:
        out.append("| " + " | ".join("-" if c is None or c == "" else str(c) for c in row) + " |")
    return "\n".join(out) + "\n"


def histogram_line(counter, order=REASONS):
    keys = [k for k in order if counter.get(k)] + [k for k in sorted(counter) if k not in order and counter[k]]
    return ", ".join(f"{k} {counter[k]}" for k in keys) or "-"


def job_rows(jobs, ordered_captures):
    """Two tables: how long each job took, and what the model saw in it."""
    order = {c: i + 1 for i, c in enumerate(ordered_captures)}
    jobs = sorted(jobs, key=lambda j: (order.get(j.capture, 999), j.claimed or datetime.max.replace(tzinfo=UTC)))
    timing, saw = [], []
    for n, j in enumerate(jobs, 1):
        seg = order.get(j.capture, n)
        t = j.complete.get("timings") or j.inference.get("timings") or {}
        d = j.download
        mbps = d.get("mbps")
        if mbps is None and d.get("bytes") and d.get("duration_ms"):
            mbps = d["bytes"] * 8 / 1000 / max(d["duration_ms"], 1)
        wait = j.queue_wait_ms / 1000 if j.queue_wait_ms is not None else j.db.get("wait")
        waited = seconds(wait) if wait is not None else (f"~{j.est_wait:.1f}" if j.est_wait is not None else "-")
        timing.append(
            [
                seg, short(j.id), short(j.capture), len(j.starts) or "-", waited,
                f"{d['duration_ms']} / {megabytes(d.get('bytes'))} / {seconds(mbps)} / {d.get('parts', '-')}" if d else "-",
                j.inference.get("inference_ms", "-"),
                "/".join(str(round(t[k])) if k in t else "-" for k in ("decoding_ms", "detection_ms", "embedding_ms", "matching_ms")) if t else "-",
                round(t["processing_total_ms"]) if "processing_total_ms" in t else "-",
                j.done_ms if j.done_ms is not None else "-",
                "ok" if j.done_at else (j.db.get("state") or ("failed" if j.failures else "?")),
            ]
        )
        q = j.complete.get("quality") or j.inference.get("quality") or {}
        rejects = j.complete.get("reject_reasons") or j.inference.get("reject_reasons") or {}
        detections = q.get("detections")
        rr = q.get("quality_rejects")
        saw.append(
            [
                seg, short(j.id), q.get("sampled_frames", "-"), detections if detections is not None else "-",
                f"{rr} ({round(100 * rr / detections)}%)" if rr is not None and detections else (rr if rr is not None else "-"),
                ", ".join(f"{k} {v}" for k, v in sorted(rejects.items(), key=lambda kv: -kv[1])) or "-",
                t.get("embed_every", "-"), round(t["embedded_faces"]) if "embedded_faces" in t else "-",
                j.complete.get("face_px_median", j.inference.get("face_px_median", "-")),
                j.complete.get("sample_fps", j.inference.get("sample_fps", "-")),
                f"{j.complete.get('recognised', '-')}/{j.complete.get('roster', '-')}",
                histogram_line(j.complete.get("reasons") or {}),
            ]
        )
    return timing, saw


def ids_suffix(d):
    parts = [f"{label} {short(d[key])}" for key, label in (("capture_id", "capture"), ("job_id", "job")) if d.get(key)]
    return f"  [{', '.join(parts)}]" if parts else ""


def describe(e):
    text = describe_event(e)
    return text + ids_suffix(e.d) if text and e.name != "client_event" else text


def describe_event(e):
    """One line for the timeline, or None to leave an event out of it."""
    n, d = e.name, e.d
    if n == "client_event":
        extra = []
        for key in ("code", "count", "attempt", "bytes", "duration_ms", "seconds", "route", "http_status"):
            if key in d:
                extra.append(f"{key}={d[key]}")
        return f"APP {d.get('kind')} " + " ".join(extra) + (f"  ({d.get('platform')})" if d.get("kind") == "scan_started" else "")
    if n == "request":
        status, route = d.get("status", 0), d.get("route", "")
        mutating = d.get("method") != "GET"
        if status >= 400 or (mutating and not route.startswith("/internal/v1/jobs/")):
            return f"API {d.get('method')} {route} -> {status}" + (f" {d.get('code')}" if d.get("code") else "") + f" ({d.get('duration_ms')} ms, req {short(d.get('request_id'))})"
        return None
    labels = {
        "job_dispatched": "AGENT handed a job to the worker",
        "job_claimed": "API leased a job",
        "job_start": "WORKER job started",
        "download_done": f"WORKER downloaded {megabytes(d.get('bytes'))} MB in {d.get('duration_ms')} ms",
        "inference_done": f"WORKER inference {d.get('inference_ms')} ms",
        "job_done": f"WORKER job done, {d.get('total_ms')} ms in all",
        "recognition_complete": f"API result stored: {d.get('recognised')}/{d.get('roster')} recognised, reasons {histogram_line(d.get('reasons') or {})}",
        "job_failed": f"{'API' if e.service == 'api' else 'WORKER'} job FAILED code={d.get('code')} stage={d.get('stage', '-')} attempts={d.get('attempts', '-')}",
        "worker_error": f"WORKER error stage={d.get('stage')} {d.get('error')}",
        "lease_lost": f"WORKER lost the lease ({d.get('reason')})",
        "lease_expired": "API leases expired",
        "processing_stalled": "API processing stalled (no worker picked the jobs up)",
        "inference_timeout": "WORKER inference timed out",
        "complete_not_accepted": f"WORKER result not accepted status={d.get('status')}",
        "client_events_rejected": f"API {d.get('count')} app events were not understood",
        "database_error": f"API database error {d.get('error')}",
        "unhandled_error": f"API unhandled error {d.get('error')} at {d.get('where')}",
    }
    return labels.get(n)


def build_timeline(mine, start, end, limit=220):
    rows, polls = [], []
    for e in mine:
        if not (start <= e.at <= end):
            continue
        if e.name == "request" and e.get("method") == "GET" and e.get("status", 0) < 400:
            polls.append(e)
            continue
        text = describe(e)
        if text:
            rows.append((e.at, text))
    if polls:
        rows.append((polls[0].at, f"API {len(polls)} read requests (polling) until {clock(polls[-1].at)}"))
    rows.sort(key=lambda r: r[0])
    out = [f"{clock(t)}  {text}" for t, text in rows]
    if len(out) > limit:
        out = out[: limit // 2] + [f"... {len(out) - limit} lines left out ..."] + out[-limit // 2 :]
    return out


def resource_summary(events):
    cpu, load, mem, disk, backlog = [], [], [], [], []
    mem_total = None
    for e in events:
        if e.name != "resources":
            continue
        d = e.d
        if "cpu_percent" in d:
            cpu.append(d["cpu_percent"])
        if "load1" in d:
            load.append(d["load1"])
        if "mem_available_mb" in d:
            mem.append(d["mem_available_mb"])
        if "disk_free_gb" in d:
            disk.append(d["disk_free_gb"])
        if "backlog" in d:
            backlog.append(d["backlog"])
        mem_total = d.get("mem_total_mb", mem_total)
    return {"cpu": cpu, "load": load, "mem": mem, "disk": disk, "backlog": backlog, "mem_total": mem_total, "n": len(cpu) or len(load)}


def analyse_api(events):
    """Errors and slow requests among the given events."""
    errors = defaultdict(list)
    slow = []
    for e in events:
        if e.name != "request":
            continue
        d = e.d
        route, status = d.get("route", ""), d.get("status", 0)
        if status >= 400:
            errors[(route, status, d.get("code") or "-")].append(e)
        elif d.get("duration_ms", 0) >= SLOW_REQUEST_MS and not route.startswith("/internal/v1/jobs/claim"):
            slow.append(e)
    return errors, slow


# ----------------------------------------------------------------------------------------------
# findings
# ----------------------------------------------------------------------------------------------
def findings_for(sid, mine, jobs, db_info, resources, errors, slow, all_events, coverage):
    out = []  # (rank, text); 0 = problem, 1 = warning, 2 = note

    def add(rank, text):
        out.append((rank, text))

    client = [e for e in mine if e.name == "client_event"]
    kinds = Counter(e.get("kind") for e in client)
    by_kind = defaultdict(list)
    for e in client:
        by_kind[e.get("kind")].append(e)

    # coverage ----------------------------------------------------------------------------------
    if coverage.get("no_logs"):
        first = f" The oldest line available is from {clock(coverage['first'], True)} UTC." if coverage.get("first") else ""
        add(0, "The logs hold NO lines for this class, so only database facts are shown." + first +
               " Docker deletes a container's log when the container is recreated (every deploy); install the persistent "
               "log capture (docs/MONDAY_DIAGNOSTICS.md) so later classes are kept. If the capture is installed, widen --since.")
    elif not client:
        add(1, "No app diagnostics arrived for this class. Either the app build is older than the "
               "diagnostics, the phone/laptop could not reach the server, or nothing was recorded. "
               "Segments and uploads can only be judged from the server side.")
    first_client = min((e.at for e in client), default=None)
    if first_client and coverage.get("first") and coverage["first"] > first_client + timedelta(seconds=5):
        add(1, f"The captured server log starts at {clock(coverage['first'])} UTC, later than the first app event "
               f"({clock(first_client)}). Earlier server lines were lost, probably to a deploy before the log capture was installed.")

    # scan lifecycle -----------------------------------------------------------------------------
    started, stopped = kinds.get("scan_started", 0), kinds.get("scan_stopped", 0)
    if started and not stopped:
        add(1, f"The scan started ({started}x) but no 'scan stopped' event arrived: the app was closed, crashed, lost power or "
               "network before the teacher stopped it, or the final batch was never delivered.")
    recorded = max((e.get("count") or 0 for e in by_kind.get("segment_recorded", [])), default=0)
    uploaded = max((e.get("count") or 0 for e in by_kind.get("upload_done", [])), default=0)
    if recorded and uploaded < recorded:
        add(0 if uploaded == 0 else 1, f"{recorded} segment(s) were recorded on the device but only {uploaded} upload(s) finished. "
               "The rest were still waiting, failed, or the app closed before they went out (they stay on the device and "
               "resume when the app is reopened).")
    if recorded == 0 and started:
        add(0, "The scan started but no segment was ever recorded: the camera produced no video "
               "(see the camera events and the camera section below).")
    retries = by_kind.get("upload_retry", [])
    if retries:
        codes = Counter(e.get("code") or "-" for e in retries)
        add(1, f"{len(retries)} upload retr{'y' if len(retries) == 1 else 'ies'} (reasons: {histogram_line(codes, ())}). "
               "A retry means a segment's upload failed and was repeated; check the phone's connection.")
    failed = by_kind.get("upload_failed", [])
    for e in failed:
        add(0, f"An upload FAILED ({e.get('code')}, after {e.get('attempt')} attempt(s)) at {clock(e.at)}. "
               "That segment is not in the attendance unless it was re-sent later.")
    for e in by_kind.get("camera_failed", []):
        add(0, f"Camera failure at {clock(e.at)} ({e.get('code')}): the camera could not be opened, was lost, or a switch failed.")
    for e in by_kind.get("camera_interrupted", []):
        add(1, f"The camera was interrupted at {clock(e.at)} ({e.get('code')}): the recording stopped because the app went to the background, "
               "the screen turned off, a call arrived or the device took the camera away.")
    for e in by_kind.get("scan_paused", []):
        add(1, f"The scan was paused at {clock(e.at)} ({e.get('code')}), for {seconds(e.get('seconds'))} s if it resumed: "
               "the screen turned off or the app left the foreground during the scan, so no video was recorded in that time.")
    if kinds.get("camera_switched"):
        add(2, f"The camera was switched {kinds['camera_switched']} time(s) ({histogram_line(Counter(e.get('code') for e in by_kind['camera_switched']), ())}).")
    if kinds.get("camera_recovered"):
        add(2, f"The camera was recovered after a disconnect {kinds['camera_recovered']} time(s).")
    for e in by_kind.get("recognition_load_failed", []):
        add(1, f"The app could not load the recognition results at {clock(e.at)} (HTTP {e.get('http_status', 'none')}): the teacher may have seen an empty or stale list.")
    for e in by_kind.get("app_error", []):
        add(1, f"The app reported an internal error at {clock(e.at)} ({e.get('code') or 'no code'}).")
    if kinds.get("api_error"):
        merged = sum(e.get("count") or 1 for e in by_kind["api_error"])
        codes = Counter()
        for e in by_kind["api_error"]:
            codes[f"{e.get('route', '-')} {e.get('http_status', 'no response')} {e.get('code', '')}".strip()] += e.get("count") or 1
        add(1, f"The app saw {merged} failed API call(s): " + "; ".join(f"{k} x{v}" for k, v in codes.most_common(5)) + ".")
        ghosts = []
        server_errors = [x for x in all_events if x.name == "request" and x.get("status", 0) >= 500]
        for e in by_kind["api_error"]:
            status = e.get("http_status")
            if status in (None, 0, 502, 503, 504) and not any(abs((s.at - e.at).total_seconds()) < 10 for s in server_errors):
                ghosts.append(e)
        if ghosts:
            add(1, f"{len(ghosts)} app-side failure(s) (status {sorted({g.get('http_status', 'none') for g in ghosts}, key=str)}) have no matching error in the server log: "
                   "the request failed between the app and the API (proxy, network, or the server restarting at that moment).")
    if by_kind.get("upload_done"):
        slow_up = []
        for e in by_kind["upload_done"]:
            n = e.get("count")
            seg = next((s for s in by_kind.get("segment_recorded", []) if s.get("count") == n), None)
            if seg and seg.get("bytes") and e.get("duration_ms"):
                mbps = seg.get("bytes") * 8 / 1000 / e.get("duration_ms")
                slow_up.append((n, mbps, e.get("duration_ms"), seg.get("bytes")))
        if slow_up:
            worst = min(slow_up, key=lambda r: r[1])
            add(2, f"Uploads: {len(slow_up)} measured, between {min(r[1] for r in slow_up):.1f} and {max(r[1] for r in slow_up):.1f} Mbps "
                   f"(slowest: segment {worst[0]}, {worst[3] / 1e6:.1f} MB in {worst[2] / 1000:.1f} s).")
        times = sorted(s.at for s in by_kind.get("segment_recorded", []))
        if len(times) >= 3:
            gap = statistics.median((b - a).total_seconds() for a, b in zip(times, times[1:], strict=False))
            durations = [e.get("duration_ms", 0) / 1000 for e in by_kind["upload_done"]]
            if durations and statistics.median(durations) > gap * 0.9:
                add(1, f"Uploads take about as long ({statistics.median(durations):.1f} s) as a segment takes to record ({gap:.1f} s): "
                       "on a slower connection the uploads fall behind and finish minutes after the scan.")
    rejected = [e for e in all_events if e.name == "client_events_rejected"]
    if rejected:
        add(2, f"The server skipped {sum(e.get('count', 0) for e in rejected)} app event(s) it did not recognise (app and server versions differ).")

    # pipeline -------------------------------------------------------------------------------------
    recog = [j for j in jobs if j.kind == "recognition" or j.complete]
    for j in recog:
        label = f"job {short(j.id)}"
        wait = j.queue_wait_ms / 1000 if j.queue_wait_ms is not None else j.db.get("wait", j.est_wait)
        if wait is not None and wait > SLOW_QUEUE_S:
            add(1, f"{label} waited{' about' if j.queue_wait_ms is None and 'wait' not in j.db else ''} {wait:.0f} s in the queue before a worker took it (more than {SLOW_QUEUE_S} s): the worker was busy or not running.")
        d = j.download
        if d and d.get("duration_ms"):
            mbps = d.get("mbps") or d["bytes"] * 8 / 1000 / max(d["duration_ms"], 1)
            if mbps < SLOW_DOWNLOAD_MBPS and d["duration_ms"] > 5000:
                add(1, f"{label} took {d['duration_ms'] / 1000:.1f} s to download {d['bytes'] / 1e6:.1f} MB from storage (about {mbps:.0f} Mbps): "
                       "slow link between the VM and Supabase Storage.")
        q = j.complete.get("quality") or j.inference.get("quality") or {}
        det, rr, frames = q.get("detections"), q.get("quality_rejects"), q.get("sampled_frames")
        if frames and det == 0:
            add(0, f"{label}: {frames} frames were sampled but NO face was detected at all. The camera may have been pointing away, covered, or the picture was unusable.")
        elif frames is not None and frames < 2:
            add(0, f"{label}: fewer than 2 frames could be read from the video: the file is too short or damaged.")
        elif det and rr is not None and rr / det > 0.5:
            rejects = j.complete.get("reject_reasons") or j.inference.get("reject_reasons") or {}
            top = max(rejects, key=rejects.get) if rejects else None
            add(1, f"{label}: {round(100 * rr / det)}% of detected faces were rejected as unusable"
                   + (f"; mostly '{top}' ({GATE_ADVICE.get(top, top)})." if top else "."))
        fps = j.complete.get("sample_fps", j.inference.get("sample_fps"))
        if fps is not None and 0 < fps < 2:
            add(1, f"{label}: only {fps} frames per second were analysed, so brief appearances can be missed.")
        t = j.complete.get("timings") or j.inference.get("timings") or {}
        if t.get("embed_every", 1) > 1:
            add(2, f"{label}: the crowd was large, so only every {round(t['embed_every'])}th frame was embedded (thinned) to keep processing fast.")
        total = j.done_ms
        if total and total > 60000:
            add(1, f"{label} took {total / 1000:.0f} s from start to finish.")
        for e in j.failures:
            add(0, f"{label} FAILED ({e.get('code') or e.get('error') or e.name}, stage {e.get('stage', '-')}, attempt {e.get('attempts', '?')}"
                   + (", will retry" if e.get("will_retry") else "") + f") at {clock(e.ts)}.")
        for e in j.lease_lost:
            add(1, f"{label} lost its lease at {clock(e.ts)} ({e.get('reason')}): the work was taken over or abandoned; the result may have come from a retry.")
        if len(j.starts) > 1:
            add(1, f"{label} was started {len(j.starts)} times (retried).")
        dbj = j.db
        if dbj and dbj.get("state") not in ("succeeded", None):
            add(0, f"{label} is '{dbj['state']}' in the database (stage {dbj.get('stage')}, error {dbj.get('error') or 'none'}) - it did not finish.")
    if db_info and db_info.get("captures"):
        stuck = [c for c in db_info["captures"] if c["status"] not in ("review_required",)]
        for c in stuck:
            add(0 if c["status"] in ("failed", "expired", "awaiting_upload") else 1,
                f"Capture {short(c['id'])} is '{c['status']}' in the database: it was not processed into a result.")
    if recog and db_info and db_info.get("captures") and len(recog) < len(db_info["captures"]):
        add(1, f"The database holds {len(db_info['captures'])} capture(s) but the logs show results for only {len(recog)}; either they never finished or their log lines are missing.")
    for e in [x for x in mine if x.name in ("processing_stalled", "lease_expired")]:
        add(0 if e.name == "processing_stalled" else 1, f"{e.name.replace('_', ' ')} at {clock(e.ts)}: no recognition worker was picking up this class's jobs.")

    # reasons ---------------------------------------------------------------------------------------
    totals = Counter()
    roster = None
    for j in recog:
        for k, v in (j.complete.get("reasons") or {}).items():
            totals[k] += v
        roster = j.complete.get("roster", roster)
    if db_info and db_info.get("attendance"):
        final = Counter()
        for r in db_info["attendance"]:
            if r["reason"] != "-":
                final[r["reason"]] += r["count"]
        if final.get("look_alike"):
            add(1, f"{final['look_alike']} student(s) look too similar to another student on the roster ('look_alike'): they need a person to confirm.")
        if final.get("seen_too_briefly"):
            add(1, f"{final['seen_too_briefly']} student(s) were seen only briefly ('seen_too_briefly'): they passed the camera too fast or were mostly hidden.")
        if final.get("weak_match"):
            add(1, f"{final['weak_match']} student(s) had only a weak match ('weak_match'): lighting, angle or an old enrolment photo.")
        if roster and final.get("not_seen", 0) > roster / 2:
            add(1, f"{final['not_seen']} of {roster} students were never seen by any segment ('not_seen'): the camera did not cover them, or the faces were too small/blurred.")
    elif roster and totals.get("not_seen", 0) > roster / 2 * max(1, len(recog)) / max(1, len(recog)):
        pass

    # server ----------------------------------------------------------------------------------------------
    for (route, status, code), items in sorted(errors.items(), key=lambda kv: -len(kv[1])):
        if status >= 500:
            add(0, f"{len(items)} server error(s) {status} {code} on {route} (e.g. request {short(items[0].get('request_id'))} at {clock(items[0].ts)}).")
        elif status in (401, 403, 409, 429) or len(items) >= 5:
            add(1 if len(items) >= 3 else 2, f"{len(items)} x {status} {code} on {route} (e.g. request {short(items[0].get('request_id'))}).")
    by_route = defaultdict(list)
    for e in slow:
        by_route[e.get("route")].append(e)
    for route, items in sorted(by_route.items(), key=lambda kv: -len(kv[1])):
        worst = max(items, key=lambda x: x.get("duration_ms"))
        background = route.startswith("/internal/v1/")
        add(2 if background else 1,
            f"{len(items)} slow request(s) (3 s or more) on {route}: slowest {worst.get('duration_ms') / 1000:.1f} s "
            f"(database wait {worst.get('db_checkout_ms', 0)} ms, request {short(worst.get('request_id'))})"
            + ("; background work of the worker, each database round trip to Tokyo costs about 0.13 s." if background else "."))
    pool = [e for e in all_events if e.name == "request" and e.get("db_checkout_ms", 0) > 500]
    if pool:
        add(1, f"{len(pool)} request(s) waited over 0.5 s for a database connection: the connection pool was saturated.")
    for e in [x for x in all_events if x.name in ("database_error", "unhandled_error")]:
        add(0, f"{e.name.replace('_', ' ')} at {clock(e.ts)} ({e.get('error')}{', ' + str(e.get('where')) if e.get('where') else ''}, request {short(e.get('request_id'))}).")
    for e in [x for x in all_events if x.name == "agent_notice" and x.get("level") in ("warning", "error")]:
        add(1, f"Agent notice at {clock(e.ts)}: {e.get('message')} (repeated {e.get('repeats', 1)}x).")
    busy = [x for x in all_events if x.name == "agent_notice" and "busy" in str(x.get("message", "")).lower()]
    if busy:
        add(2, f"The worker was busy and held back {len(busy)} time(s); max backlog {max((x.get('backlog', 0) for x in busy), default=0)}.")

    # resources ---------------------------------------------------------------------------------------------
    r = resources
    if r["cpu"] and max(r["cpu"]) >= 90:
        add(1, f"CPU reached {max(r['cpu']):.0f}% (average {statistics.mean(r['cpu']):.0f}%): the VM was saturated; processing slows down further when burst credits run out.")
    if r["load"] and max(r["load"]) > 6:
        add(1, f"Load average reached {max(r['load']):.1f} (the VM has 4 vCPUs): more work than the machine could run at once.")
    if r["mem"] and min(r["mem"]) < 1000:
        add(0, f"Available memory fell to {min(r['mem'])} MB: the machine was close to running out of memory.")
    if r["disk"] and min(r["disk"]) < 5:
        add(0, f"Only {min(r['disk']):.1f} GB of disk was free.")
    if r["backlog"] and max(r["backlog"]) >= 3:
        add(1, f"The job backlog reached {max(r['backlog'])}: jobs queued up faster than they were processed.")
    if not r["n"]:
        add(2, "No resource readings fall in this window (the agent logs one a minute): the agent may not have been running.")

    out.sort(key=lambda x: x[0])
    seen, unique = set(), []
    for rank, text in out:
        if text not in seen:
            seen.add(text)
            unique.append((rank, text))
    return unique


# ----------------------------------------------------------------------------------------------
# report assembly
# ----------------------------------------------------------------------------------------------
PRESENT = {"present", "late"}
ABSENT = {"absent", "excused"}
NOT_PROPOSED = {"not_recognized", "limited_capture"}


def review_effort(rows):
    """How much the teacher changed what the system proposed, from the grouped attendance rows.

    The system's own proposal is overwritten when the teacher decides, so this is inferred by
    comparing the assessment code with the final status. It is a review-effort figure, not an
    accuracy measurement. Counts only: no student is identified."""
    out = {"proposed": 0, "removed": 0, "added": 0, "not_proposed": 0, "manual_no_face": 0, "undecided": 0}
    for r in rows:
        n, code, status = r["count"], r["code"], r["status"]
        if code == "recognized":
            out["proposed"] += n
            if status in ABSENT:
                out["removed"] += n
            elif status not in PRESENT:
                out["undecided"] += n
        elif code in NOT_PROPOSED:
            out["not_proposed"] += n
            if status in PRESENT:
                out["added"] += n
            elif status not in ABSENT:
                out["undecided"] += n
        elif code == "template_ineligible" and status in PRESENT:
            out["manual_no_face"] += n
    judged = out["proposed"] + out["not_proposed"]
    out["changed"] = out["removed"] + out["added"]
    out["judged"] = judged
    out["changed_pct"] = round(100 * out["changed"] / judged, 1) if judged else None
    return out


def review_effort_lines(effort):
    if not effort["judged"]:
        return ["- Teacher review effort: nothing to compare yet (no recognised or unrecognised students with a face enrolment)."]
    lines = [
        f"- Teacher review effort: the system proposed {effort['proposed']} student(s) as present; the teacher removed "
        f"{effort['removed']} of them. Of {effort['not_proposed']} not proposed, the teacher marked {effort['added']} present. "
        f"Changed {effort['changed']} of {effort['judged']} ({effort['changed_pct']}%)."
    ]
    if effort["manual_no_face"]:
        lines.append(f"- {effort['manual_no_face']} student(s) without a face enrolment were marked present by hand (not counted above).")
    if effort["undecided"]:
        lines.append(f"- {effort['undecided']} row(s) have no teacher decision yet, so the figure may still change.")
    lines.append("  _Inferred by comparing the system's reason with the final status; the original proposal is not stored. "
                 "A review-effort figure, not an accuracy rate._")
    return lines


def render_session(sid, analysis, db_info, coverage, all_events):
    mine, captures, job_ids = analysis.for_session(sid, db_info)
    start, end = window(mine, db_info)
    if start is None:
        return f"## Session {sid}\n\nNo log lines mention this session in the window searched. Widen it with `--since 3d`.\n"
    jobs = [analysis.jobs[j] for j in job_ids if j in analysis.jobs]
    if db_info and db_info.get("jobs"):
        by_id = {j.id: j for j in jobs}
        for row in db_info["jobs"]:
            job = by_id.get(row["id"]) or analysis.job(row["id"])
            if job not in jobs:
                jobs.append(job)
            job.capture = job.capture or row["capture"]
            job.kind = job.kind or row["kind"]
            job.db = {"state": row["state"], "stage": row["stage"], "attempts": row["attempts"], "error": row["error"], "created": row["created"]}
            if job.claimed and row["created"]:
                job.db["wait"] = (job.claimed - row["created"]).total_seconds()
    window_events = in_window(all_events, start, end)
    recognition_jobs = [j for j in jobs if j.kind in (None, "recognition") or j.complete]
    # Without the database or capture ids in the job lines, pair the n-th upload with the n-th job.
    uploads = sorted(
        (e for e in window_events if e.name == "request" and e.get("route", "").endswith("/upload-complete") and e.get("status", 500) < 400),
        key=lambda e: e.ts,
    )
    pending = sorted((j for j in recognition_jobs if j.claimed), key=lambda j: j.claimed)
    if len(uploads) >= len(pending):
        for upload, job in zip(uploads[len(uploads) - len(pending):], pending, strict=False):
            job.est_wait = max(0.0, (job.claimed - upload.ts).total_seconds())
    ordered = [c["id"] for c in db_info["captures"]] if db_info and db_info.get("captures") else [
        j.capture for j in sorted(recognition_jobs, key=lambda x: x.claimed or datetime.max.replace(tzinfo=UTC)) if j.capture
    ]
    errors, slow = analyse_api(window_events)
    resources = resource_summary(window_events)
    coverage = {**coverage, "no_logs": not mine}
    # Errors the app reports carry no session id; those inside this class's window belong to it.
    mine_ids = {id(e) for e in mine}
    extra = [e for e in window_events if e.name == "client_event" and id(e) not in mine_ids and not e.get("session_id")
             and e.get("kind") in ("api_error", "app_error", "recognition_load_failed")]
    mine = sorted(mine + extra, key=lambda e: e.ts)
    client = [e for e in mine if e.name == "client_event"]
    findings = findings_for(sid, mine, recognition_jobs, db_info, resources, errors, slow, window_events, coverage)

    out = [f"## Session `{sid}`", ""]
    meta = [f"window {clock(start, True)} to {clock(end, True)} UTC"]
    if db_info and "status" in db_info:
        meta.append(f"status **{db_info['status']}**, revision {db_info['revision']}, roster {db_info['roster']}")
    out.append("; ".join(meta))
    if db_info and db_info.get("error"):
        out.append(f"\n_Database part unavailable ({db_info['error']}); this section is built from logs only._")
    if db_info and db_info.get("missing"):
        out.append("\n_The database has no such session (wrong id, or a different project)._")
    out.append("")

    # summary --------------------------------------------------------------------------------------------
    kinds = Counter(e.get("kind") for e in client)
    recorded = max((e.get("count") or 0 for e in client if e.get("kind") == "segment_recorded"), default=0)
    uploaded = max((e.get("count") or 0 for e in client if e.get("kind") == "upload_done"), default=0)
    done = sum(1 for j in recognition_jobs if j.complete)
    out += [
        "### Summary",
        "",
        f"- App: scan started {kinds.get('scan_started', 0)}x, stopped {kinds.get('scan_stopped', 0)}x; segments recorded {recorded}, uploads finished {uploaded}.",
        f"- Server: {len(recognition_jobs)} recognition job(s) seen, {done} with a stored result.",
    ]
    if db_info and db_info.get("attendance"):
        counts = Counter()
        for r in db_info["attendance"]:
            counts[r["status"]] += r["count"]
        out.append("- Final attendance statuses in the database: " + ", ".join(f"{k} {v}" for k, v in sorted(counts.items())) + ".")
    contexts = Counter(
        f"{e.get('client')}/{e.get('platform')} v{e.get('version', '?')} {e.get('device_class', '')} {e.get('network', '')} {e.get('net_class', '')}".strip()
        for e in client
    )
    if contexts:
        out.append("- Clients: " + "; ".join(f"{k} ({v} events)" for k, v in contexts.most_common(4)) + ".")
    out.append("")

    # findings ------------------------------------------------------------------------------------------------
    out += ["### Findings", ""]
    tags = {0: "**PROBLEM**", 1: "**Warning**", 2: "Note"}
    if findings:
        out += [f"{n}. {tags[rank]}: {text}" for n, (rank, text) in enumerate(findings, 1)]
    else:
        out.append("Nothing unusual found in the data that exists. (Absence of events is not proof: see the coverage line at the top.)")
    out.append("")

    # timeline -----------------------------------------------------------------------------------------------------
    out += ["### Timeline (UTC; app events are placed at the time they happened on the device)", "", "```"]
    out += build_timeline(mine, start, end) or ["(no events)"]
    out += ["```", ""]

    # jobs ------------------------------------------------------------------------------------------------------------
    timing, saw = job_rows(recognition_jobs, ordered)
    out += ["### Jobs: timing", "",
            "Stage times (decode/detect/embed/match) are sums across threads and can exceed wall time; read `processing wall` and `job total` for real time.", "",
            table(["seg", "job", "capture", "starts", "queue wait s", "download ms / MB / Mbps / parts", "inference ms",
                   "decode/detect/embed/match ms", "processing wall ms", "job total ms", "outcome"], timing), ""]
    out += ["### Jobs: what the model saw", "",
            table(["seg", "job", "frames", "detections", "rejected", "rejects by gate", "embed every", "faces embedded",
                   "face px median", "sample fps", "recognised/roster", "reasons"], saw), ""]
    totals = Counter()
    for j in recognition_jobs:
        for k, v in (j.complete.get("reasons") or {}).items():
            totals[k] += v
    out += ["### Why students were or were not recognised", "",
            "Per segment (each segment is judged against the whole roster, so a student can be 'not_seen' in one segment and recognised in another):", "",
            f"- all segments added up: {histogram_line(totals)}"]
    if db_info and db_info.get("attendance"):
        final = Counter()
        for r in db_info["attendance"]:
            final[r["reason"] if r["reason"] != "-" else r["code"]] += r["count"]
        out.append(f"- final per-student state in the database: {histogram_line(final)}")
        if db_info["observations"]:
            out.append("- observations behind the non-recognised: " + "; ".join(
                f"{k}: {v['count']} students, {v['min']}-{v['max']} (median {v['median']})" for k, v in db_info["observations"].items()))
        if db_info["closeness"]:
            out.append("- best similarity of non-recognised students (buckets of 0.1, counts only): " + ", ".join(f"{b:+.1f}: {n}" for b, n in db_info["closeness"]))
        out += ["", "Final attendance records:", "",
                table(["status", "source", "assessment", "reason", "students"],
                      [[r["status"], r["source"], r["code"], r["reason"], r["count"]] for r in db_info["attendance"]])]
        out += ["", *review_effort_lines(review_effort(db_info["attendance"]))]
    out.append("")

    # captures (database) ---------------------------------------------------------------------------------------------------
    if db_info and db_info.get("captures"):
        rows = []
        for n, c in enumerate(db_info["captures"], 1):
            job = next((j for j in jobs if j.capture == c["id"] and (j.kind in (None, "recognition") or j.complete)), None)
            rows.append([n, short(c["id"]), c["source"], c["status"], clock(c["created"]), megabytes(c["bytes"]), c["media"],
                         job.db.get("state") if job else "-", job.db.get("attempts") if job else "-"])
        out += ["### Captures in the database", "", table(["seg", "capture", "source", "status", "created UTC", "MB", "media", "job state", "attempts"], rows), ""]

    # client ----------------------------------------------------------------------------------------------------------------------
    if client:
        ups = [e for e in client if e.get("kind") == "upload_done"]
        rows = []
        for e in ups:
            seg = next((s for s in client if s.get("kind") == "segment_recorded" and s.get("count") == e.get("count")), None)
            mbps = seg.get("bytes") * 8 / 1000 / e.get("duration_ms") if seg and seg.get("bytes") and e.get("duration_ms") else None
            rows.append([e.get("count"), clock(e.at), megabytes(seg.get("bytes")) if seg else "-", e.get("duration_ms"), seconds(mbps), e.get("attempt", 0)])
        out += ["### Uploads seen by the app", "", table(["segment", "finished UTC", "MB", "upload ms", "Mbps", "retries before success"], rows), ""]
        other = Counter(e.get("kind") for e in client if e.get("kind") not in ("segment_recorded", "upload_done"))
        out += [f"App events by kind: {histogram_line(other, ())}.", ""]

    # server errors ------------------------------------------------------------------------------------------------------------------
    out += ["### API errors in the window (by route and code)", ""]
    rows = [[route, status, code, len(items), ", ".join(short(i.get("request_id")) for i in items[:4])]
            for (route, status, code), items in sorted(errors.items(), key=lambda kv: -len(kv[1]))]
    out += [table(["route", "status", "code", "count", "request ids (first 8 chars)"], rows), ""]
    out += ["### Slow requests (3 s or more; job polling excluded)", "",
            table(["time UTC", "route", "status", "ms", "db wait ms", "request"],
                  [[clock(e.ts), e.get("route"), e.get("status"), e.get("duration_ms"), e.get("db_checkout_ms"), short(e.get("request_id"))] for e in slow[:15]]), ""]

    # worker/agent warnings ----------------------------------------------------------------------------------------------------------------
    names = ("lease_lost", "lease_expired", "job_failed", "worker_error", "inference_timeout", "complete_not_accepted",
             "processing_stalled", "agent_notice", "agent_recovered", "handoff_abandoned", "claim_paused", "download_ranges_unsupported")
    rows = [[clock(e.ts), e.service, e.name, e.get("level", "-"),
             " ".join(f"{k}={e.get(k)}" for k in ("job_id", "code", "stage", "reason", "message", "repeats", "backlog") if e.get(k) is not None)[:150]]
            for e in window_events if e.name in names or (e.get("level") in ("warning", "error") and e.name not in ("request", "client_event"))]
    out += ["### Worker and agent notices", "", table(["time UTC", "service", "event", "level", "detail"], rows[:40]), ""]

    # resources ----------------------------------------------------------------------------------------------------------------------------
    r = resources
    def span(values, fmt="{:.0f}"):
        return f"min {fmt.format(min(values))}, avg {fmt.format(statistics.mean(values))}, max {fmt.format(max(values))}" if values else "no readings"
    out += ["### Server resources in the window (one reading a minute)", "",
            f"- CPU %: {span(r['cpu'])}", f"- load (1 min): {span(r['load'], '{:.1f}')}",
            f"- memory available MB: {span(r['mem'])}" + (f" of {r['mem_total']}" if r['mem_total'] else ""),
            f"- disk free GB: {span(r['disk'], '{:.1f}')}", f"- job backlog: {span(r['backlog'])}", ""]
    return "\n".join(out)


def rollup(selected, db):
    """Counts added up across the sessions in the window. Aggregates only."""
    rows, used = [], 0
    for sid in selected:
        info = load_session_db(db, sid)
        if info and info.get("attendance"):
            rows += info["attendance"]
            used += 1
    if not used:
        return ""
    effort = review_effort(rows)
    reasons = Counter()
    for r in rows:
        reasons[r["reason"] if r["reason"] != "-" else r["code"]] += r["count"]
    return "\n".join([f"## Across {used} session(s)", "", *review_effort_lines(effort), "",
                      f"- final per-student state, all sessions: {histogram_line(reasons)}"])


def make_report(events, total_lines, target, since_seconds, db=None, live_now=None, sources="", out_of_scope_note=""):
    analysis = Analysis(events)
    anchor = live_now or (events[-1].ts if events else datetime.now(UTC))
    cutoff = anchor - timedelta(seconds=since_seconds)
    coverage = {"first": events[0].ts if events else None, "last": events[-1].ts if events else None}
    active = {s: t for s, t in analysis.sessions().items() if t >= cutoff}
    explicit = target if target and UUID.match(target) else None
    if explicit:
        selected = [explicit]
    elif target == "latest":
        pool = analysis.sessions()
        selected = [max(pool, key=pool.get)] if pool else []
    else:
        selected = sorted(active, key=active.get)
    db_ok = db is not None and getattr(db, "conn", None) is not None
    if not selected and db_ok and not explicit:
        try:
            rows = db.rows("recent", cutoff)
            selected = [str(r[0]) for r in rows[: 1 if target == "latest" else 10]]
            db.conn.rollback()
        except Exception:  # noqa: BLE001
            selected = []
    head = ["# FaceTrack session report", "",
            f"Generated {clock(datetime.now(UTC), True)} UTC. Sources: {sources or 'logs'}. "
            f"Log lines read: {total_lines}, events parsed: {len(events)}"
            + (f", from {clock(coverage['first'], True)} to {clock(coverage['last'], True)} UTC." if events else "."),
            ""]
    if db is None:
        head.append("Database: not queried (`--no-db`).")
    elif not db_ok:
        head.append(f"Database: **unavailable** ({db.error}). Job states, capture status and final attendance are missing; queue wait is computed only where the logs carry it.")
    else:
        head.append("Database: queried read-only (ids and aggregate counts only; no names, scores or enrolment numbers).")
    if not events:
        head += ["", "**No log events were found.** Check the source (`--vm`, `--logs-dir`, or `--stdin`) and that "
                 "log capture is installed (docs/MONDAY_DIAGNOSTICS.md)."]
    head.append("")
    body = []
    for sid in selected:
        info = load_session_db(db, sid) if db_ok else None
        body.append(render_session(sid, analysis, info, coverage, events))
    if not selected:
        body.append("No class activity found in this window. Other sessions appear only when someone scans, uploads or opens/closes them; "
                    "pass a session id explicitly or widen `--since`.")
    if len(selected) > 1 and db_ok:
        body.append(rollup(selected, db))
    viewed = {e.get("session_id") for e in events if e.get("session_id")} - set(selected)
    if viewed and not explicit:
        body.append(f"\n_Sessions that were only viewed (no scan or upload): {', '.join(short(v) for v in sorted(viewed))}._")
    # server-wide notices outside any selected session's window
    return "\n".join(head) + "\n" + "\n\n".join(body) + "\n"


# ----------------------------------------------------------------------------------------------
# command line
# ----------------------------------------------------------------------------------------------
def since_seconds(text):
    found = SINCE.match(text or "")
    if not found:
        raise SystemExit("--since must look like 90s, 30m, 3h or 2d")
    return int(found.group(1)) * {"s": 1, "m": 60, "h": 3600, "d": 86400}[found.group(2)]


def main(argv=None):
    parser = argparse.ArgumentParser(description="One-command diagnostic report for a class.")
    parser.add_argument("target", nargs="?", help="session id, or 'latest'")
    parser.add_argument("--since", default=None, help="window, e.g. 3h (default 24h); with no target, every class active in it")
    parser.add_argument("--vm", action="store_true", help="read the Azure VM's logs over ssh")
    parser.add_argument("--stdin", action="store_true", help="read log lines from standard input")
    parser.add_argument("--file", action="append", default=[], help="a log file (.gz ok); repeatable")
    parser.add_argument("--logs-dir", help="a directory of captured logs (a copy of /var/log/facetrack)")
    parser.add_argument("--no-db", action="store_true", help="do not query the database")
    parser.add_argument("--out", help="write the report to this file")
    args = parser.parse_args(argv)
    if not args.target and not args.since:
        parser.error("give a session id, 'latest', or --since 3h")
    if args.target and args.target != "latest" and not UUID.match(args.target):
        parser.error("the target must be a session id (UUID) or 'latest'")
    window_text = args.since or "24h"
    seconds_back = since_seconds(window_text)

    sources, live = [], None
    if args.stdin:
        lines, sources = sys.stdin, ["stdin"]
    elif args.file or args.logs_dir:
        def gather():
            for path in args.file:
                with open_text(path) as handle:
                    yield from handle
            if args.logs_dir:
                yield from lines_from_dir(args.logs_dir)
        lines, sources = gather(), [*args.file, *([args.logs_dir] if args.logs_dir else [])]
    else:
        lines = lines_from_script(args.vm, window_text if args.since or not args.target else "24h")
        sources, live = [("VM" if args.vm else "local Docker") + f" logs, last {window_text}"], datetime.now(UTC)
    events, total = read_events(lines)
    # an explicit session id may be older than the window: widen to everything that was read
    if args.target and UUID.match(args.target) and not args.since:
        seconds_back = 10**9
    db = None if args.no_db else Database()
    try:
        report = make_report(events, total, args.target, seconds_back, db, live, ", ".join(map(str, sources)))
    finally:
        if db is not None:
            db.close()
    if args.out:
        Path(args.out).write_text(report)
        print(f"Report written to {args.out}", file=sys.stderr)
    else:
        sys.stdout.write(report)
    return 0


if __name__ == "__main__":
    sys.exit(main())
