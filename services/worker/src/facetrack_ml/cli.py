from __future__ import annotations

import argparse
import json
import platform
import sys
from pathlib import Path

import onnxruntime as ort

from .capture import validate_capture
from .config import Profile, canonical_hash, load_manifest, load_profile
from .errors import SpikeError
from .media import executable, probe
from .pipeline import Pipeline
from .runtime import Runtime
from .store import TemplateStore, atomic_private_write, cleanup_media, participant_id


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description="Local FaceTrack ML spike; no automatic model downloads.")
    root.add_argument("--data-root", type=Path, default=Path(".local/spike"))
    sub = root.add_subparsers(dest="command", required=True)
    sub.add_parser("doctor", help="Inspect runtime and decoding prerequisites")
    p = sub.add_parser("probe", help="Validate video without face recognition")
    p.add_argument("video", type=Path)
    p.add_argument("--metadata", type=Path, help="Validate the paired browser JSON export too")
    p = sub.add_parser("models", help="Verify permission, evidence, hashes and real ONNX execution")
    p.add_argument("--manifest", type=Path, required=True)
    p = sub.add_parser("profile", help="Freeze explicit experimental calibration settings")
    p.add_argument("--manifest", type=Path, required=True)
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--calibration-id", required=True)
    p.add_argument("--identity-threshold", type=float, required=True)
    p.add_argument("--minimum-margin", type=float, required=True)
    p.add_argument("--enrollment-consistency", type=float, required=True)
    p.add_argument("--blur-variance", type=float, default=40.0,
                   help="Experimental crop-quality floor; calibrate on separate recordings")
    for command in ("enrol", "recognize", "benchmark"):
        p = sub.add_parser(command)
        p.add_argument("video", type=Path)
        p.add_argument("--manifest", type=Path, required=True)
        p.add_argument("--profile", type=Path, required=True)
        p.add_argument("--out", type=Path)
        if command == "enrol":
            p.add_argument("--metadata", type=Path, help="Check paired reference export and identity")
            p.add_argument("--participant", required=True)
            p.add_argument("--consent", action="store_true", required=True,
                           help="Confirm this participant explicitly consented")
            p.add_argument("--supervised-pose-review", action="store_true", required=True,
                           help="Confirm identity and front/up/down/left/right coverage in person")
        else:
            p.add_argument("--roster", nargs="+", required=True)
        if command == "benchmark":
            p.add_argument("--runs", type=int, default=3)
    p = sub.add_parser("revoke", help="Delete a participant's local templates")
    p.add_argument("--participant", required=True)
    sub.add_parser("cleanup", help="Delete managed raw media older than 24 hours")
    return root


def execute(args) -> dict:
    if args.command == "doctor":
        return {"python": platform.python_version(), "architecture": platform.machine(),
                "onnxruntime": ort.__version__, "available_providers": ort.get_available_providers(),
                "ffmpeg_available": bool(executable("ffmpeg")),
                "ffprobe_available": bool(executable("ffprobe")),
                "selected_provider": "CPUExecutionProvider",
                "recognition_validation": "pending_models_and_volunteer_recordings"}
    if args.command == "probe":
        if args.metadata:
            return validate_capture(args.video, args.metadata)
        info = probe(args.video)
        return {"status": "valid_media", **info.__dict__}
    if args.command == "cleanup":
        return {"status": "cleaned", "deleted_files": cleanup_media(args.data_root / "media"),
                "scope": "managed_media_only", "retention_hours": 24}
    if args.command == "revoke":
        TemplateStore(args.data_root / "templates").revoke(args.participant)
        return {"status": "revoked", "participant_id": participant_id(args.participant)}
    if args.command == "profile":
        manifest = load_manifest(args.manifest)
        if args.out.exists():
            raise SpikeError("PROFILE_EXISTS", "Frozen profiles are immutable; choose a new filename.")
        profile = Profile(model_hash=canonical_hash(manifest.model_dump()),
                          calibration_id=args.calibration_id,
                          identity_threshold=args.identity_threshold,
                          minimum_margin=args.minimum_margin,
                          enrollment_consistency=args.enrollment_consistency,
                          blur_variance=args.blur_variance)
        atomic_private_write(args.out, json.dumps(profile.model_dump(), indent=2).encode())
        return {"status": "experimental_profile_frozen", "profile_hash":
                canonical_hash(profile.model_dump()), "production_validated": False}
    if args.command == "enrol" and args.metadata:
        validate_capture(args.video, args.metadata, participant=args.participant)
    runtime = Runtime(args.manifest)
    model_hash = canonical_hash(runtime.manifest.model_dump())
    if args.command == "models":
        return {"status": "local_use_verified", "model_hash": model_hash,
                "provider": "CPUExecutionProvider", "cold_start_ms": runtime.cold_start_ms,
                "production_permission": "not_established_by_local_approval"}
    profile = load_profile(args.profile, model_hash)
    pipeline = Pipeline(runtime, profile, model_hash)
    store = TemplateStore(args.data_root / "templates")
    if args.command == "enrol":
        return pipeline.enrol(args.video, participant_id(args.participant), store)
    if args.command == "recognize":
        return pipeline.recognize(args.video, args.roster, store)
    if not 1 <= args.runs <= 20:
        raise SpikeError("INVALID_RUN_COUNT", "Benchmark runs must be between 1 and 20.")
    runs = [pipeline.recognize(args.video, args.roster, store) for _ in range(args.runs)]
    return {"status": "benchmark_complete", "runs": runs, "model_hash": model_hash,
            "profile_hash": pipeline.profile_hash,
            "note": "One model initialization; repeated same-clip runs measure speed, not accuracy."}


def main():
    args = parser().parse_args()
    try:
        result = execute(args)
        if getattr(args, "out", None) and args.command != "profile":
            atomic_private_write(args.out, json.dumps(result, indent=2, allow_nan=False).encode())
        print(json.dumps(result, indent=2, allow_nan=False))
    except SpikeError as error:
        print(json.dumps({"error": {"code": error.code, "message": str(error)}}), file=sys.stderr)
        return 2
    except Exception:
        # Native runtime/validation exceptions must not print paths or template contents.
        print(json.dumps({"error": {"code": "PROCESSING_FAILED", "message":
                                   "Processing failed. Check model/configuration and local inputs."}}),
              file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
