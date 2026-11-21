"""Child-process adapter. No changes to frozen inference or participant data."""

import csv
import subprocess
from contextlib import contextmanager
from pathlib import Path

from facetrack_ml.config import canonical_hash, load_manifest, load_profile
from facetrack_ml.errors import SpikeError
from facetrack_ml.media import executable, probe

from . import media_cache

# numpy, OpenCV, ONNX Runtime and the dense sampler are imported inside the functions that need
# them: report and timetable jobs share this child entry point and never touch a model.


class Collector:
    def save(self, person, vectors, model_hash, profile_hash):
        import numpy as np

        if vectors.shape[1] != 512 or not 3 <= len(vectors) <= 5 or not np.isfinite(vectors).all():
            raise SpikeError("INVALID_TEMPLATES", "Invalid enrolment output.")
        self.templates = [
            {"ordinal": n, "pose": "unverified", "vector": v.tolist()}
            for n, v in enumerate(vectors)
        ]


def normalize_rotation(source, directory, *, enrollment=True):
    try:
        # Remembered, so the dense sampler does not run ffprobe on the same file again.
        media_cache.once(
            ("probe", enrollment), source, lambda: probe(source, enrollment=enrollment)
        )
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
    media_cache.once(("probe", enrollment), target, lambda: probe(target, enrollment=enrollment))
    return target


@contextmanager
def single_thread_sessions(threads=1):
    """Make every ONNX Runtime session created inside this block use ``threads`` intra-op threads.

    The frozen ``Runtime`` hard-codes four intra-op threads per session. Two jobs side by side on
    a four-core VM then run eight spinning threads, and a batch-one 112 px embedding gains little
    from the extra threads. The frozen source is not touched: while a ``Runtime`` is being built,
    the ``SessionOptions`` class it looks up is swapped for a subclass that pins the setting.
    Outputs were bit-identical across thread counts when measured (see PROGRESS.md).
    """
    import onnxruntime as ort

    original = ort.SessionOptions

    class PinnedOptions(original):
        def __setattr__(self, name, value):
            super().__setattr__(name, threads if name == "intra_op_num_threads" else value)

    ort.SessionOptions = PinnedOptions
    try:
        yield
    finally:
        ort.SessionOptions = original


def build_pipeline(manifest_path, profile, model_hash, *, parallel):
    """Frozen pipeline; with ``parallel`` its sessions are single-threaded (see above)."""
    from facetrack_ml.pipeline import Pipeline
    from facetrack_ml.runtime import Runtime

    if parallel:
        with single_thread_sessions(1):
            runtime = Runtime(Path(manifest_path))
    else:
        runtime = Runtime(Path(manifest_path))
    return Pipeline(runtime, profile, model_hash)


def run_child(pipe, source, manifest_path, profile_path, expected, wait=False):
    """Run one job. With ``wait`` the child loads the models first, then blocks until the parent
    has finished downloading and verifying the media and sends ``("go",)``: model loading then
    overlaps the download instead of following it."""
    try:
        source = Path(source)
        if expected.get("kind") == "report":
            from .tabular import report

            pipe.send({"ok": True, "result": {"kind": "report", **report(expected["snapshot"])}})
            return
        if expected.get("kind") == "timetable":
            from .tabular import parse_csv

            if media_cache.sha256(source) != expected["source_sha256"]:
                raise ValueError("CSV hash mismatch.")
            pipe.send(
                {
                    "ok": True,
                    "result": {
                        "kind": "timetable",
                        "rows": parse_csv(source),
                        "source_sha256": media_cache.sha256(source),
                    },
                }
            )
            return
        # The artifact hashes are checked by Runtime() below, so this read skips them.
        manifest = load_manifest(Path(manifest_path), check_artifacts=False)
        model_hash = canonical_hash(manifest.model_dump())
        profile = load_profile(Path(profile_path), model_hash)
        profile_hash = canonical_hash(profile.model_dump())
        if model_hash != expected["model_hash"] or profile_hash != expected["profile_hash"]:
            raise SpikeError("INPUT_CHANGED", "Model/profile/source differs from the leased input.")
        recognition = expected.get("kind") == "recognition"
        from . import dense

        threads = dense.worker_threads() if recognition else 0
        parallel = recognition and dense.sample_fps() > 0 and threads >= 2
        pipeline = build_pipeline(
            manifest_path, profile, model_hash, parallel=parallel and dense.pin_sessions()
        )
        if wait:
            try:
                pipe.recv()  # the parent has the verified media in place
            except EOFError:
                return  # the parent gave up (download failed, lease lost): nothing to report
        if media_cache.sha256(source) != expected["source_sha256"]:
            raise SpikeError("INPUT_CHANGED", "Model/profile/source differs from the leased input.")
        processed = normalize_rotation(source, source.parent, enrollment=not recognition)
        collector = Collector()
        if recognition:
            import numpy as np

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

            people = [p["student_id"] for p in expected["roster"]]
            fps = dense.sample_fps()
            last = {"stage": None, "percent": -100}

            def report(stage, percent=None):
                # Progress for the teacher's screen, sent at most every 10 percent per stage.
                changed = stage != last["stage"] or percent is None or percent >= 100
                if changed or percent - last["percent"] >= 10:
                    last.update(stage=stage, percent=percent or 0)
                    pipe.send({"progress": {"stage": stage, "percent": percent}})

            if fps > 0:
                result = dense.recognize(
                    pipeline,
                    processed,
                    people,
                    Roster(),
                    fps,
                    progress=report,
                    threads=threads if parallel else 1,
                )
            else:
                result = pipeline.recognize(processed, people, Roster())
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
                        "source_sha256": media_cache.sha256(source),
                        "processed_sha256": media_cache.sha256(processed),
                        "model_hash": model_hash,
                        "profile_hash": profile_hash,
                        "roster_hash": expected["roster_hash"],
                        "proposals": proposals,
                        "unknown_observations": result["unknown_observations"],
                        "quality": result["quality"],
                        "timings": result["timings"],
                        **{
                            k: result[k]
                            for k in ("diagnostics", "reject_reasons", "face_px_median", "sample_fps")
                            if k in result
                        },
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
                    "source_sha256": media_cache.sha256(source),
                    "processed_sha256": media_cache.sha256(processed),
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
    except (ValueError, csv.Error):
        pipe.send({"ok": False, "code": "INVALID_DOCUMENT", "retryable": False})
    except subprocess.CalledProcessError:
        # ffmpeg rejected the upload; the same input fails the same way on retry.
        pipe.send({"ok": False, "code": "INVALID_MEDIA", "retryable": False})
    except subprocess.TimeoutExpired:
        pipe.send({"ok": False, "code": "PROCESS_TIMEOUT", "retryable": True})
    except Exception:
        pipe.send({"ok": False, "code": "WORKER_ERROR", "retryable": True})
    finally:
        pipe.close()
