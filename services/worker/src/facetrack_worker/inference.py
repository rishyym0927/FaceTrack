"""Child-process adapter. No changes to frozen inference or participant data."""

import subprocess
from pathlib import Path

import numpy as np

from facetrack_ml.config import canonical_hash, digest, load_manifest, load_profile
from facetrack_ml.errors import SpikeError
from facetrack_ml.media import executable, probe
from facetrack_ml.pipeline import Pipeline
from facetrack_ml.runtime import Runtime


class Collector:
    def save(self, person, vectors, model_hash, profile_hash):
        if vectors.shape[1] != 512 or not 3 <= len(vectors) <= 5 or not np.isfinite(vectors).all():
            raise SpikeError("INVALID_TEMPLATES", "Invalid enrolment output.")
        self.templates = [
            {"ordinal": n, "pose": "unverified", "vector": v.tolist()}
            for n, v in enumerate(vectors)
        ]


def normalize_rotation(source, directory, *, enrollment=True):
    try:
        probe(source, enrollment=enrollment)
        return source
    except SpikeError as e:
        if e.code != "ROTATED_MEDIA":
            raise
    target = directory / "upright.mp4"
    # Only rotate metadata-bearing input after all preceding frozen probe bounds passed.
    # No face enhancement, upscaling or audio stripping as a way to accept disallowed audio.
    subprocess.run(
        [
            executable("ffmpeg"),
            "-nostdin",
            "-v",
            "error",
            "-protocol_whitelist",
            "file,pipe",
            "-i",
            str(source),
            "-map",
            "0:v:0",
            "-an",
            "-vf",
            "scale=w='min(iw,1280)':h='min(ih,720)':force_original_aspect_ratio=decrease:force_divisible_by=2",
            "-c:v",
            "libx264",
            "-preset",
            "veryfast",
            "-crf",
            "18",
            "-pix_fmt",
            "yuv420p",
            "-metadata:s:v:0",
            "rotate=0",
            "-fs",
            str(25 * 1024 * 1024),
            str(target),
        ],
        check=True,
        capture_output=True,
        timeout=60,
    )
    target.chmod(0o600)
    probe(target, enrollment=enrollment)
    return target


def run_child(pipe, source, manifest_path, profile_path, expected):
    try:
        source = Path(source)
        if expected.get("kind") == "report":
            from .tabular import report

            pipe.send({"ok": True, "result": {"kind": "report", **report(expected["snapshot"])}})
            return
        if expected.get("kind") == "timetable":
            from .tabular import parse_csv

            if digest(source) != expected["source_sha256"]:
                raise ValueError("CSV hash mismatch.")
            pipe.send(
                {
                    "ok": True,
                    "result": {
                        "kind": "timetable",
                        "rows": parse_csv(source),
                        "source_sha256": digest(source),
                    },
                }
            )
            return
        manifest = load_manifest(Path(manifest_path))
        model_hash = canonical_hash(manifest.model_dump())
        profile = load_profile(Path(profile_path), model_hash)
        profile_hash = canonical_hash(profile.model_dump())
        if (
            model_hash != expected["model_hash"]
            or profile_hash != expected["profile_hash"]
            or digest(source) != expected["source_sha256"]
        ):
            raise SpikeError("INPUT_CHANGED", "Model/profile/source differs from the leased input.")
        recognition = expected.get("kind") == "recognition"
        processed = normalize_rotation(source, source.parent, enrollment=not recognition)
        collector = Collector()
        pipeline = Pipeline(Runtime(Path(manifest_path)), profile, model_hash)
        if recognition:

            class Roster:
                def load(self, people, model_hash, profile_hash):
                    if (
                        model_hash != expected["model_hash"]
                        or profile_hash != expected["profile_hash"]
                    ):
                        raise SpikeError("INPUT_CHANGED", "Incompatible roster.")
                    return {
                        p["student_id"]: np.asarray(p["vectors"], dtype=np.float32)
                        for p in expected["roster"]
                        if p["student_id"] in people
                    }

            result = pipeline.recognize(
                processed, [p["student_id"] for p in expected["roster"]], Roster()
            )
            identities = {p["student_id"]: p for p in expected["roster"]}
            proposals = []
            for p in result["proposals"]:
                ref = identities[p["participant_id"]]
                proposals.append(
                    {
                        "student_id": ref["student_id"],
                        "template_set_id": ref["template_set_id"],
                        "template_epoch": ref["template_epoch"],
                        "hits": p["hits"],
                        "span_ms": p["span_ms"],
                        "similarity": p["median_similarity"],
                    }
                )
            pipe.send(
                {
                    "ok": True,
                    "result": {
                        "generation": expected["generation"],
                        "source_sha256": digest(source),
                        "processed_sha256": digest(processed),
                        "model_hash": model_hash,
                        "profile_hash": profile_hash,
                        "roster_hash": expected["roster_hash"],
                        "proposals": proposals,
                        "unknown_observations": result["unknown_observations"],
                        "quality": result["quality"],
                        "timings": result["timings"],
                    },
                }
            )
            return
        result = pipeline.enrol(processed, "isolated-enrollment", collector)
        pipe.send(
            {
                "ok": True,
                "result": {
                    "generation": expected["generation"],
                    "source_sha256": digest(source),
                    "processed_sha256": digest(processed),
                    "model_hash": model_hash,
                    "profile_hash": profile_hash,
                    "templates": collector.templates,
                    "quality": result["quality"],
                    "timings": result["timings"],
                },
            }
        )
    except SpikeError as e:
        pipe.send({"ok": False, "code": e.code, "retryable": False})
    except ValueError:
        pipe.send({"ok": False, "code": "INVALID_DOCUMENT", "retryable": False})
    except subprocess.TimeoutExpired:
        pipe.send({"ok": False, "code": "PROCESS_TIMEOUT", "retryable": True})
    except Exception:
        pipe.send({"ok": False, "code": "WORKER_ERROR", "retryable": True})
    finally:
        pipe.close()
