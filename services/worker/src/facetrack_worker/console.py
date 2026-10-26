"""Local ML Test Console: a guided way to try the *frozen* recognition model on volunteers.

Everything here is additive. The frozen model, profile, thresholds and inference code are only
called through the existing ``facetrack_ml.cli`` commands in a fresh process, exactly like the
research spike. Nothing is imported by the API, the Celery worker or the product apps, and no
database, Supabase or attendance record is touched.

Privacy: the service binds to loopback, checks Host/Origin, keeps volunteer labels only in a
private local file, deletes every uploaded clip as soon as it is processed, and exports only
aggregate counts with pseudonymous IDs.

    python -m facetrack_worker.console
"""

from __future__ import annotations

import json
import mimetypes
import os
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from facetrack_ml.config import canonical_hash, digest, load_manifest, load_profile
from facetrack_ml.errors import SpikeError

REPEATS = 3
MAX_ENROL_BYTES = 25 * 1024 * 1024
MAX_RUN_BYTES = 50 * 1024 * 1024
LABEL_PATTERN = re.compile(r"^[^\x00-\x1f<>]{1,40}$")
PID_PATTERN = re.compile(r"^p[0-9]{2,4}$")

SCENARIOS: dict[str, dict] = {
    "both_known": {
        "title": "Everyone enrolled is present",
        "how": "Two or more enrolled volunteers sit in view and look at the camera. No other faces.",
        "min_present": 2, "unknown": False, "needs_absent": False,
    },
    "one_absent": {
        "title": "One enrolled person is absent",
        "how": "Record without at least one enrolled volunteer. Tick only the people who are visible.",
        "min_present": 1, "unknown": False, "needs_absent": True,
    },
    "unknown_only": {
        "title": "Only a stranger is present",
        "how": "Someone who has NOT been enrolled sits alone in view. Nobody enrolled is visible.",
        "min_present": 0, "max_present": 0, "unknown": True, "needs_absent": False,
    },
    "known_plus_unknown": {
        "title": "Enrolled person plus a stranger",
        "how": "One or more enrolled volunteers sit with one person who has NOT been enrolled.",
        "min_present": 1, "unknown": True, "needs_absent": False,
    },
    "position_scale": {
        "title": "Different positions and distances",
        "how": "Two or more enrolled volunteers at different distances, turning their heads slightly.",
        "min_present": 2, "unknown": False, "needs_absent": False,
    },
    "no_face": {
        "title": "Nobody in view",
        "how": "An empty scene: nobody visible at all.",
        "min_present": 0, "max_present": 0, "unknown": False, "needs_absent": False,
    },
}

FRIENDLY = {
    "MULTIPLE_FACES": "More than one face was visible during enrolment. Re-record with only that person in view.",
    "ENROLLMENT_QUALITY": "Not enough clear face views. Use brighter light, face the camera, and follow the head-turn prompts.",
    "INCONSISTENT_IDENTITY": "The enrolment frames did not look like one consistent person. Re-record with one person only.",
    "CLIP_TOO_SHORT": "The recording was too short. Record the full time.",
    "NO_FRAMES": "The video could not be read. Please record again.",
    "INVALID_MEDIA": "The video file could not be read. Please record again.",
    "AUDIO_NOT_ALLOWED": "The video contains audio, which is not allowed. Record without a microphone.",
    "ALREADY_ENROLLED": "That volunteer is already enrolled.",
    "TEMPLATE_VERSION_MISMATCH": "The saved volunteers were made with other model settings. Delete all test data and start again.",
    "MODEL_PERMISSION_REQUIRED": "The model files are not approved on this computer. Contact the project owner.",
    "MODEL_HASH_MISMATCH": "A model file is missing or has changed. Contact the project owner.",
    "LICENSE_EVIDENCE_MISMATCH": "The model licence evidence is missing or changed. Contact the project owner.",
}


class ConsoleError(Exception):
    def __init__(self, code: str, message: str | None = None, status: int = 422):
        super().__init__(code)
        self.code, self.status = code, status
        self.message = message or FRIENDLY.get(code, "Processing failed. Please record again.")


def sha256_file(path: Path) -> str:
    return digest(path)


class ConsoleService:
    """All behaviour lives here so it can be tested without HTTP."""

    def __init__(self, root: Path, manifest: Path, profile: Path, receipt: Path | None = None,
                 repo_root: Path | None = None):
        self.root = root.resolve()
        self.manifest, self.profile = Path(manifest), Path(profile)
        self.receipt = Path(receipt) if receipt else None
        self.repo_root = Path(repo_root) if repo_root else None
        self.engine = self.root / "engine"
        self.media = self.root / "media"
        self.lock = threading.Lock()
        for directory in (self.root, self.engine, self.media):
            directory.mkdir(parents=True, exist_ok=True)
            directory.chmod(0o700)

    # ---- small private files -------------------------------------------------------------
    def _read(self, name: str, default):
        path = self.root / name
        try:
            return json.loads(path.read_text())
        except (OSError, ValueError):
            return default

    def _write(self, name: str, value) -> None:
        path = self.root / name
        fd, temp = tempfile.mkstemp(dir=self.root)
        try:
            with os.fdopen(fd, "w") as stream:
                json.dump(value, stream, indent=2, sort_keys=True)
            os.chmod(temp, 0o600)
            os.replace(temp, path)
        finally:
            if os.path.exists(temp):
                os.unlink(temp)

    def _people(self) -> dict:
        return self._read("people.json", {})

    def _attempts(self) -> list[dict]:
        path = self.root / "attempts.jsonl"
        if not path.exists():
            return []
        rows = []
        for line in path.read_text().splitlines():
            try:
                rows.append(json.loads(line))
            except ValueError:
                continue
        return rows

    def _append_attempt(self, row: dict) -> None:
        path = self.root / "attempts.jsonl"
        with path.open("a") as stream:
            stream.write(json.dumps(row, sort_keys=True) + "\n")
        path.chmod(0o600)

    # ---- integrity -----------------------------------------------------------------------
    def integrity(self) -> dict:
        """Confirm the model, profile and inference source have not changed since first use."""
        try:
            manifest = load_manifest(self.manifest)
            model_hash = canonical_hash(manifest.model_dump())
            load_profile(self.profile, model_hash)
        except SpikeError as error:
            return {"ok": False, "code": error.code,
                    "message": FRIENDLY.get(error.code, "The model or settings could not be verified.")}
        import facetrack_ml

        source = Path(facetrack_ml.__file__).resolve().parent
        files = {"manifest": self.manifest, "profile": self.profile,
                 "detector": self.manifest.parent / manifest.detector.file,
                 "recognizer": self.manifest.parent / manifest.recognizer.file}
        files.update({f"source/{p.name}": p for p in sorted(source.glob("*.py"))})
        current = {name: sha256_file(path) for name, path in files.items() if path.is_file()}
        pinned = self._read("frozen-pin.json", None)
        first_use = pinned is None
        if first_use:
            self._write("frozen-pin.json", current)
            pinned = current
        changed = sorted(name for name in set(pinned) | set(current)
                         if pinned.get(name) != current.get(name))
        receipt = {"checked": 0, "matched": 0}
        if self.receipt and self.receipt.is_file() and self.repo_root:
            try:
                expected = json.loads(self.receipt.read_text())["frozen_files_sha256"]
                for relative, value in expected.items():
                    path = self.repo_root / relative
                    if path.is_file() and not path.is_symlink():
                        receipt["checked"] += 1
                        receipt["matched"] += int(sha256_file(path) == value)
            except (OSError, ValueError, KeyError, TypeError, AttributeError):
                pass
        ok = not changed and receipt["checked"] == receipt["matched"]
        return {"ok": ok, "first_use": first_use, "changed": changed, "receipt": receipt,
                "model_hash_prefix": model_hash[:12],
                "message": "Model and settings are unchanged." if ok else
                "The model or settings changed since testing began. Stop and contact the project owner."}

    # ---- subprocess to the existing frozen CLI ---------------------------------------------
    def _cli(self, *args: str, timeout: int = 300) -> dict:
        command = [sys.executable, "-m", "facetrack_ml.cli", "--data-root", str(self.engine), *args]
        try:
            done = subprocess.run(command, capture_output=True, text=True, timeout=timeout,
                                  cwd=self.root, check=False)
        except subprocess.TimeoutExpired as error:
            raise ConsoleError("PROCESS_TIMEOUT", "Processing took too long. Please try again.",
                               504) from error
        if done.returncode == 0:
            try:
                return json.loads(done.stdout)
            except ValueError as error:
                raise ConsoleError("PROCESSING_FAILED") from error
        code = "PROCESSING_FAILED"
        try:
            code = json.loads(done.stderr.strip().splitlines()[-1])["error"]["code"]
        except (ValueError, KeyError, IndexError, TypeError):
            pass
        raise ConsoleError(code)

    def _prepare_video(self, path: Path, *, enrollment: bool) -> Path:
        from .inference import normalize_rotation

        try:
            return normalize_rotation(path, path.parent, enrollment=enrollment)
        except SpikeError as error:
            raise ConsoleError(error.code) from error
        except Exception as error:  # noqa: BLE001 - never leak native errors
            raise ConsoleError("INVALID_MEDIA") from error

    # ---- people ----------------------------------------------------------------------------
    def list_people(self) -> list[dict]:
        people = self._people()
        return [{"id": pid, "label": info["label"], "enrolled_at": info["enrolled_at"]}
                for pid, info in sorted(people.items())]

    def _next_id(self) -> str:
        used = {int(p[1:]) for p in self._people()}
        used |= {int(p.stem[1:]) for p in (self.engine / "templates").glob("p*.enc")
                 if PID_PATTERN.fullmatch(p.stem)}
        number = max(used, default=0) + 1
        if number > 9999:
            raise ConsoleError("TOO_MANY_PEOPLE", "Too many volunteers.", 409)
        return f"p{number:02d}"

    def enrol(self, label: str, video: Path, *, consent: bool, supervised: bool) -> dict:
        if not (consent and supervised):
            raise ConsoleError("CONSENT_REQUIRED",
                               "Tick both boxes: the volunteer consented, and you watched the recording.",
                               400)
        label = label.strip()
        if not LABEL_PATTERN.fullmatch(label):
            raise ConsoleError("INVALID_LABEL", "Enter a name or nickname (1–40 characters).", 400)
        if not self._acquire():
            raise ConsoleError("BUSY", "Another step is still running. Please wait.", 409)
        try:
            self._require_integrity()
            pid = self._next_id()
            processed = self._prepare_video(video, enrollment=True)
            result = self._cli("enrol", str(processed), "--participant", pid, "--manifest",
                               str(self.manifest), "--profile", str(self.profile), "--consent",
                               "--supervised-pose-review")
            people = self._people()
            people[pid] = {"label": label, "enrolled_at": int(time.time())}
            self._write("people.json", people)
            return {"id": pid, "label": label, "templates": result.get("template_count", 0)}
        finally:
            self.lock.release()

    def remove_person(self, pid: str) -> None:
        if not PID_PATTERN.fullmatch(pid):
            raise ConsoleError("INVALID_ID", "Unknown volunteer.", 404)
        if not self._acquire():
            raise ConsoleError("BUSY", "Another step is still running. Please wait.", 409)
        try:
            people = self._people()
            if pid not in people:
                raise ConsoleError("INVALID_ID", "Unknown volunteer.", 404)
            (self.engine / "templates" / f"{pid}.enc").unlink(missing_ok=True)
            del people[pid]
            self._write("people.json", people)
        finally:
            self.lock.release()

    # ---- scenarios -------------------------------------------------------------------------
    def scenarios(self) -> list[dict]:
        return [{"id": key, "title": spec["title"], "how": spec["how"],
                 "unknown_person": spec["unknown"],
                 "min_present": spec["min_present"], "max_present": spec.get("max_present")}
                for key, spec in SCENARIOS.items()]

    def _validate_truth(self, scenario: str, present: list[str], unknown: bool, enrolled: list[str]):
        spec = SCENARIOS.get(scenario)
        if spec is None:
            raise ConsoleError("INVALID_SCENARIO", "Unknown scenario.", 400)
        if len(set(present)) != len(present) or any(p not in enrolled for p in present):
            raise ConsoleError("INVALID_TRUTH", "Tick only enrolled volunteers who are visible.", 400)
        if len(present) < spec["min_present"]:
            raise ConsoleError("INVALID_TRUTH",
                               f"For this scenario, at least {spec['min_present']} enrolled "
                               "volunteer(s) must be visible.", 400)
        if "max_present" in spec and len(present) > spec["max_present"]:
            raise ConsoleError("INVALID_TRUTH", "For this scenario no enrolled volunteer may be visible.",
                               400)
        if unknown != spec["unknown"]:
            raise ConsoleError("INVALID_TRUTH", "This scenario " + (
                "needs exactly one stranger who has not been enrolled." if spec["unknown"]
                else "must not include anyone who has not been enrolled."), 400)
        if spec["needs_absent"] and len(present) >= len(enrolled):
            raise ConsoleError("INVALID_TRUTH",
                               "At least one enrolled volunteer must be absent from this recording.", 400)

    def run(self, scenario: str, present: list[str], unknown: bool, video: Path) -> dict:
        enrolled = sorted(self._people())
        if len(enrolled) < 2:
            raise ConsoleError("NEED_TWO_PEOPLE", "Enrol at least two volunteers first.", 409)
        self._validate_truth(scenario, present, unknown, enrolled)
        if not self._acquire():
            raise ConsoleError("BUSY", "Another step is still running. Please wait.", 409)
        started = time.perf_counter()
        attempt = {"attempt_id": uuid.uuid4().hex[:12], "at": int(time.time()), "scenario": scenario,
                   "expected": sorted(present), "stranger_present": unknown,
                   "roster_size": len(enrolled), "media_sha256_prefix": sha256_file(video)[:12]}
        try:
            self._require_integrity()
            processed = self._prepare_video(video, enrollment=False)
            outcomes = []
            for _ in range(REPEATS):
                result = self._cli("recognize", str(processed), "--roster", *enrolled, "--manifest",
                                   str(self.manifest), "--profile", str(self.profile))
                outcomes.append(result)
        except ConsoleError as error:
            self._append_attempt({**attempt, "status": "rejected_input", "code": error.code})
            raise
        finally:
            self.lock.release()
        suggested = [sorted(p["participant_id"] for p in r["proposals"]) for r in outcomes]
        stable = all(item == suggested[0] for item in suggested)
        proposed, expected = set(suggested[0]), set(present)
        false_presence, missed = sorted(proposed - expected), sorted(expected - proposed)
        quality = outcomes[0].get("quality", {})
        row = {**attempt, "status": "scored", "suggested": sorted(proposed), "correct": not (
            false_presence or missed), "false_presence": false_presence, "missed": missed,
            "stable_across_repeats": stable, "repeats": REPEATS,
            "unknown_observations": outcomes[0].get("unknown_observations", 0),
            "sampled_frames": quality.get("sampled_frames", 0),
            "detections": quality.get("detections", 0),
            "quality_rejects": quality.get("quality_rejects", 0),
            "processing_ms": [round(r.get("timings", {}).get("processing_total_ms", 0), 1)
                              for r in outcomes],
            "wall_seconds": round(time.perf_counter() - started, 1)}
        self._append_attempt(row)
        return self._public_attempt(row)

    def _acquire(self) -> bool:
        return self.lock.acquire(blocking=False)

    def _require_integrity(self) -> None:
        state = self.integrity()
        if not state["ok"]:
            raise ConsoleError("INTEGRITY", state["message"], 409)

    # ---- results ---------------------------------------------------------------------------
    def _public_attempt(self, row: dict) -> dict:
        names = {pid: info["label"] for pid, info in self._people().items()}
        out = dict(row)
        for key in ("expected", "suggested", "false_presence", "missed"):
            if key in out:
                out[key + "_names"] = [names.get(p, p) for p in out[key]]
        return out

    def summary(self, *, for_export: bool = False) -> dict:
        attempts = self._attempts()
        official: dict[str, dict] = {}
        counts: dict[str, dict] = {key: {"attempts": 0, "rejected": 0} for key in SCENARIOS}
        for row in attempts:
            bucket = counts.get(row.get("scenario"))
            if bucket is None:
                continue
            bucket["attempts"] += 1
            if row.get("status") == "rejected_input":
                bucket["rejected"] += 1
            elif row.get("status") == "scored" and row["scenario"] not in official:
                official[row["scenario"]] = row
        rows = []
        for key, spec in SCENARIOS.items():
            first = official.get(key)
            item = {"id": key, "title": spec["title"], **counts[key],
                    "status": "not_done" if first is None else ("pass" if first["correct"] else "fail")}
            if first is not None and not for_export:
                item["official"] = self._public_attempt(first)
            elif first is not None:
                item["official"] = {k: first[k] for k in (
                    "correct", "stable_across_repeats",
                    "unknown_observations", "sampled_frames", "detections", "quality_rejects",
                    "wall_seconds", "roster_size", "stranger_present") if k in first}
                item["official"]["false_presence_count"] = len(first.get("false_presence", []))
                item["official"]["missed_count"] = len(first.get("missed", []))
            rows.append(item)
        done = [r for r in rows if r["status"] != "not_done"]
        passed = [r for r in rows if r["status"] == "pass"]
        scored = list(official.values())
        times = [max(r["processing_ms"]) for r in scored if r.get("processing_ms")]
        total_false = sum(len(r["false_presence"]) for r in scored)
        total_missed = sum(len(r["missed"]) for r in scored)
        if len(done) < len(rows):
            verdict = f"In progress: {len(done)} of {len(rows)} scenarios done."
        elif len(passed) == len(rows):
            verdict = "All 6 scenarios matched what you expected."
        else:
            verdict = f"{len(rows) - len(passed)} of 6 scenarios did not match what you expected."
        data = {
            "title": "FaceTrack model test (controlled volunteers)",
            "disclaimer": ("Six short recordings with a few volunteers in one room. This checks the "
                           "frozen model behaves as expected; it is not a guarantee of classroom accuracy, "
                           "liveness protection or institute-scale performance."),
            "volunteers_enrolled": len(self._people()),
            "scenarios": rows, "done": len(done), "total": len(rows), "passed": len(passed),
            "false_presence_total": total_false, "missed_total": total_missed,
            "all_stable": all(r["stable_across_repeats"] for r in scored) if scored else None,
            "slowest_clip_processing_ms": max(times) if times else None,
            "median_clip_processing_ms": statistics.median(times) if times else None,
            "verdict": verdict,
            "rule": "Each scenario's first scored attempt is the official result; retries and "
                    "rejected recordings are kept in the count but never replace it.",
        }
        if for_export:
            data["attempt_log"] = [{k: v for k, v in a.items() if k not in (
                "expected", "suggested", "false_presence", "missed", "media_sha256_prefix")}
                | {"expected_count": len(a.get("expected", [])),
                   "false_presence_count": len(a.get("false_presence", [])),
                   "missed_count": len(a.get("missed", []))} for a in attempts]
            data["integrity"] = {k: v for k, v in self.integrity().items() if k != "changed"}
            data["generated_at_utc"] = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
            data["report_text"] = render_report(data)
        return data

    def status(self) -> dict:
        people = self.list_people()
        return {"service": "facetrack-test-console", "integrity": self.integrity(),
                "volunteers": people, "ready_for_scenarios": len(people) >= 2,
                "recommended_volunteers": 3, "repeats": REPEATS}

    def wipe(self) -> None:
        if not self._acquire():
            raise ConsoleError("BUSY", "Another step is still running. Please wait.", 409)
        try:
            shutil.rmtree(self.engine, ignore_errors=True)
            shutil.rmtree(self.media, ignore_errors=True)
            for name in ("people.json", "attempts.jsonl"):
                (self.root / name).unlink(missing_ok=True)
            self.engine.mkdir(mode=0o700, parents=True, exist_ok=True)
            self.media.mkdir(mode=0o700, parents=True, exist_ok=True)
        finally:
            self.lock.release()


STATUS_WORDS = {"pass": "Matched", "fail": "Did NOT match", "not_done": "Not done"}


def render_report(data: dict) -> str:
    """Plain-text report for a non-technical tester to send back. Counts only: no names, faces, videos."""
    lines = [
        data["title"], "=" * len(data["title"]),
        f"Created: {data.get('generated_at_utc', '')}",
        f"Volunteers enrolled: {data['volunteers_enrolled']}",
        "", f"RESULT: {data['verdict']}", "",
        f"Scenarios matched: {data['passed']} of {data['total']} (done: {data['done']})",
        f"Wrong 'present' suggestions (false presence): {data['false_presence_total']}",
        f"Present people the model did not suggest (misses, shown as Not recognized): {data['missed_total']}",
        "Same answer in all 3 repeated runs: " + {True: "yes", False: "NO - treat results as unreliable",
                                                  None: "not known yet"}[data["all_stable"]],
    ]
    if data.get("slowest_clip_processing_ms") is not None:
        lines.append(f"Slowest 10-second recording took {data['slowest_clip_processing_ms'] / 1000:.1f} s to check")
    lines += ["", "Per scenario (first scored attempt is the official result):"]
    for row in data["scenarios"]:
        official = row.get("official", {})
        lines.append(
            f"- {row['title']}: {STATUS_WORDS.get(row['status'], row['status'])}"
            f" | attempts {row['attempts']}, rejected recordings {row['rejected']}"
            + (f" | wrong present {official.get('false_presence_count', 0)}, misses {official.get('missed_count', 0)}"
               if official else ""))
    integrity = data.get("integrity", {})
    lines += ["", "Model check: " + str(integrity.get("message", "unknown")), "", data["disclaimer"], data["rule"]]
    return "\n".join(lines) + "\n"


# ---- HTTP ------------------------------------------------------------------------------------
class Handler(BaseHTTPRequestHandler):
    server_version = "FaceTrackConsole"
    protocol_version = "HTTP/1.1"
    service: ConsoleService
    web_dir: Path
    allowed_hosts: set[str]
    allowed_origins: set[str]

    def log_message(self, *_args) -> None:  # never log URLs, bodies or labels
        return

    def _send(self, status: int, body: bytes, content_type: str, extra: dict | None = None) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.close_connection = True
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        origin = self.headers.get("Origin")
        if origin and origin in self.allowed_origins:
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Vary", "Origin")
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def _json(self, status: int, value, extra: dict | None = None) -> None:
        self._send(status, json.dumps(value).encode(), "application/json", extra)

    def _error(self, error: ConsoleError) -> None:
        self._json(error.status, {"error": {"code": error.code, "message": error.message}})

    def _guard(self, mutating: bool) -> bool:
        if self.headers.get("Host", "") not in self.allowed_hosts:
            self._json(403, {"error": {"code": "FORBIDDEN_HOST", "message": "Forbidden."}})
            return False
        origin = self.headers.get("Origin")
        if origin and origin not in self.allowed_origins:
            self._json(403, {"error": {"code": "FORBIDDEN_ORIGIN", "message": "Forbidden."}})
            return False
        if mutating and self.headers.get("X-FaceTrack-Console") != "1":
            self._json(403, {"error": {"code": "FORBIDDEN", "message": "Forbidden."}})
            return False
        return True

    def do_OPTIONS(self) -> None:  # noqa: N802
        if not self._guard(False):
            return
        self._send(204, b"", "text/plain", {
            "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS",
            "Access-Control-Allow-Headers": "Content-Type, X-FaceTrack-Console"})

    def do_GET(self) -> None:  # noqa: N802
        if not self._guard(False):
            return
        parsed = urlparse(self.path)
        try:
            if parsed.path == "/api/status":
                return self._json(200, self.service.status())
            if parsed.path == "/api/scenarios":
                return self._json(200, {"scenarios": self.service.scenarios()})
            if parsed.path == "/api/summary":
                return self._json(200, self.service.summary())
            if parsed.path == "/api/export":
                return self._json(200, self.service.summary(for_export=True), {
                    "Content-Disposition": 'attachment; filename="facetrack-model-test.json"'})
            if parsed.path.startswith("/api/"):
                return self._json(404, {"error": {"code": "NOT_FOUND", "message": "Not found."}})
            return self._static(parsed.path)
        except ConsoleError as error:
            return self._error(error)

    def _static(self, request_path: str) -> None:
        relative = request_path.lstrip("/") or "index.html"
        root = self.web_dir.resolve()
        target = (root / relative).resolve()
        if root not in target.parents and target != root:
            return self._json(404, {"error": {"code": "NOT_FOUND", "message": "Not found."}})
        if not target.is_file():
            if relative != "index.html" and "." in Path(relative).name:
                return self._json(404, {"error": {"code": "NOT_FOUND", "message": "Not found."}})
            target = root / "index.html"
        if not target.is_file():
            page = ("<!doctype html><meta charset=utf-8><title>FaceTrack test console</title>"
                    "<h1>FaceTrack model test console</h1><p>The service is running, but the page "
                    "files are not installed. Ask the project owner to run the console build step."
                    "</p><p><a href='/api/status'>Service status</a></p>")
            return self._send(200, page.encode(), "text/html; charset=utf-8")
        types = {".js": "text/javascript", ".mjs": "text/javascript", ".wasm": "application/wasm",
                 ".json": "application/json", ".html": "text/html; charset=utf-8",
                 ".css": "text/css"}
        content_type = types.get(target.suffix) or mimetypes.guess_type(target.name)[0] or \
            "application/octet-stream"
        self._send(200, target.read_bytes(), content_type)

    def _read_body(self, limit: int) -> Path:
        try:
            length = int(self.headers.get("Content-Length", ""))
        except ValueError as error:
            raise ConsoleError("LENGTH_REQUIRED", "Upload size is required.", 411) from error
        if length <= 0 or length > limit:
            raise ConsoleError("TOO_LARGE", "The recording is too large or empty.", 413)
        fd, name = tempfile.mkstemp(dir=self.service.media, suffix=".upload")
        path = Path(name)
        try:
            remaining = length
            with os.fdopen(fd, "wb") as stream:
                while remaining:
                    chunk = self.rfile.read(min(1024 * 1024, remaining))
                    if not chunk:
                        raise ConsoleError("UPLOAD_INTERRUPTED", "Upload interrupted. Try again.", 400)
                    stream.write(chunk)
                    remaining -= len(chunk)
        except BaseException:
            path.unlink(missing_ok=True)
            raise
        kind = self.headers.get("Content-Type", "")
        suffix = ".mp4" if "mp4" in kind else ".webm" if "webm" in kind else None
        if suffix is None:
            path.unlink(missing_ok=True)
            raise ConsoleError("UNSUPPORTED_MEDIA", "Only WebM or MP4 recordings are accepted.", 415)
        final = path.with_suffix(suffix)
        path.rename(final)
        final.chmod(0o600)
        return final

    def do_POST(self) -> None:  # noqa: N802
        if not self._guard(True):
            return
        parsed = urlparse(self.path)
        query = {k: v[0] for k, v in parse_qs(parsed.query).items()}
        video: Path | None = None
        try:
            if parsed.path == "/api/people/enrol":
                video = self._read_body(MAX_ENROL_BYTES)
                result = self.service.enrol(query.get("label", ""), video,
                                            consent=query.get("consent") == "1",
                                            supervised=query.get("supervised") == "1")
                return self._json(200, result)
            if parsed.path == "/api/runs":
                video = self._read_body(MAX_RUN_BYTES)
                present = [p for p in query.get("present", "").split(",") if p]
                result = self.service.run(query.get("scenario", ""), present,
                                          query.get("stranger") == "1", video)
                return self._json(200, result)
            if parsed.path == "/api/wipe":
                if query.get("confirm") != "DELETE":
                    raise ConsoleError("CONFIRM_REQUIRED", "Confirmation required.", 400)
                self.service.wipe()
                return self._json(200, {"status": "deleted"})
            return self._json(404, {"error": {"code": "NOT_FOUND", "message": "Not found."}})
        except ConsoleError as error:
            return self._error(error)
        except Exception:  # noqa: BLE001 - no internals in responses
            return self._json(500, {"error": {"code": "SERVER_ERROR",
                                              "message": "Something went wrong. Please try again."}})
        finally:
            if video is not None:
                video.unlink(missing_ok=True)
                for leftover in video.parent.glob("upright.mp4"):
                    leftover.unlink(missing_ok=True)

    def do_DELETE(self) -> None:  # noqa: N802
        if not self._guard(True):
            return
        match = re.fullmatch(r"/api/people/(p[0-9]{2,4})", urlparse(self.path).path)
        if not match:
            return self._json(404, {"error": {"code": "NOT_FOUND", "message": "Not found."}})
        try:
            self.service.remove_person(match.group(1))
            return self._json(200, {"status": "removed"})
        except ConsoleError as error:
            return self._error(error)


def build_server(service: ConsoleService, web_dir: Path, host: str, port: int,
                 extra_origins: set[str] | None = None) -> ThreadingHTTPServer:
    hosts = {f"127.0.0.1:{port}", f"localhost:{port}"}
    origins = {f"http://{h}" for h in hosts} | set(extra_origins or ())

    class Bound(Handler):
        pass

    Bound.service, Bound.web_dir = service, Path(web_dir)
    Bound.allowed_hosts, Bound.allowed_origins = hosts, origins
    return ThreadingHTTPServer((host, port), Bound)


def main() -> None:
    repo = Path(__file__).resolve().parents[4]
    local = repo / ".local"
    root = Path(os.environ.get("CONSOLE_ROOT", local / "test-console"))
    manifest = Path(os.environ.get("MANIFEST_PATH",
                                   local / "spike/models/buffalo_sc/manifest.json"))
    profile = Path(os.environ.get("PROFILE_PATH",
                                  local / "spike/profiles/frozen-phase1b-v1.json"))
    web_dir = Path(os.environ.get("CONSOLE_WEB_DIR", local / "console-web"))
    host = os.environ.get("FACETRACK_CONSOLE_HOST", "127.0.0.1")
    port = int(os.environ.get("FACETRACK_CONSOLE_PORT", "8010"))
    extra = {o for o in os.environ.get("CONSOLE_ORIGINS", "").split(",") if o}
    service = ConsoleService(root, manifest, profile, local / "spike/held-out-freeze-v2.json", repo)
    server = build_server(service, web_dir, host, port, extra)
    print(f"FaceTrack model test console: http://127.0.0.1:{port}  (Ctrl+C to stop)", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()

