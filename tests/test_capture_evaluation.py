"""Export/experiment safeguards; synthetic media and mocked inference are NOT ML evidence."""
import importlib.util
import json
import subprocess
import sys
from types import SimpleNamespace

import numpy as np
import pytest
from facetrack_ml.capture import validate_capture
from facetrack_ml.cli import execute, parser
from facetrack_ml.config import Profile, canonical_hash, digest
from facetrack_ml.errors import SpikeError
from facetrack_ml.media import MediaInfo, executable, probe
from facetrack_ml.store import TemplateStore

spec = importlib.util.spec_from_file_location("evaluate_spike", "scripts/evaluate_spike.py")
evaluation = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = evaluation
spec.loader.exec_module(evaluation)


def metadata(**changes):
    return {"schema_version": 1, "capture_id": "1792683054865", "mode": "classroom",
            "participant_id": "p01", "dataset": "test", "duration_seconds": 10,
            "pose_prompts": [], "audio_enabled": False, "consent_confirmed": True,
            "pose_verification": "human_review_required", **changes}


def test_capture_pair_rejects_mismatch_and_missing_consent(tmp_path, monkeypatch):
    video = tmp_path / "clip.webm"
    video.write_bytes(b"synthetic placeholder; probe mocked")
    sidecar = tmp_path / "clip.json"
    monkeypatch.setattr("facetrack_ml.capture.probe", lambda *a, **k:
                        MediaInfo(320, 240, 9.94, "vp9", 1))
    sidecar.write_text(json.dumps(metadata()))
    assert validate_capture(video, sidecar)["pairing"] == "operator_supplied"
    with pytest.raises(SpikeError, match="identity must agree"):
        validate_capture(video, sidecar, participant="p02")
    sidecar.write_text(json.dumps(metadata(duration_seconds=15)))
    with pytest.raises(SpikeError) as error:
        validate_capture(video, sidecar)
    assert error.value.code == "CAPTURE_DURATION_MISMATCH"
    sidecar.write_text(json.dumps(metadata(consent_confirmed=False)))
    with pytest.raises(SpikeError) as error:
        validate_capture(video, sidecar)
    assert error.value.code == "INVALID_CAPTURE_METADATA"


def test_enrollment_sidecar_prompts_do_not_prove_poses(tmp_path, monkeypatch):
    video = tmp_path / "clip.webm"
    video.write_bytes(b"synthetic")
    sidecar = tmp_path / "clip.json"
    monkeypatch.setattr("facetrack_ml.capture.probe", lambda *a, **k:
                        MediaInfo(320, 240, 14.94, "vp9", 1))
    sidecar.write_text(json.dumps(metadata(mode="enrollment", dataset="reference",
                                          duration_seconds=15,
                                          pose_prompts=["front", "up", "down", "left", "right"])))
    result = validate_capture(video, sidecar, participant="p01")
    assert result["pose_verification"] == "human_review_required"


def test_audio_track_rejected_even_when_video_is_supported(tmp_path):
    path = tmp_path / "synthetic-with-audio.mp4"
    subprocess.run([executable("ffmpeg"), "-v", "error", "-f", "lavfi", "-i",
                    "testsrc2=size=160x120:rate=15:duration=1", "-f", "lavfi", "-i",
                    "sine=frequency=440:duration=1", "-c:v", "libx264", "-c:a", "aac",
                    "-shortest", str(path)], check=True, timeout=30)
    with pytest.raises(SpikeError) as error:
        probe(path)
    assert error.value.code == "AUDIO_NOT_ALLOWED"


def private_suite(tmp_path):
    for name in ("reference1", "reference2", "query"):
        (tmp_path / name).write_bytes(name.encode())
    (tmp_path / "query.json").write_text(json.dumps(metadata()))
    profile = tmp_path / "profile.json"
    profile.write_text("{}")
    suite = {"dataset": "test", "roster": ["p01", "p02"],
             "excluded_videos": ["reference1", "reference2"], "cases": [
                 {"case_id": "unknown", "scenario": "unknown_only", "video": "query",
                  "metadata": "query.json", "expected_present": []}]}
    path = tmp_path / "suite.json"
    path.write_text(json.dumps(suite))
    return path, profile, suite


def test_suite_rejects_reference_leakage_and_wrong_split(tmp_path, monkeypatch):
    path, profile, suite = private_suite(tmp_path)
    monkeypatch.setattr("facetrack_ml.capture.probe", lambda *a, **k:
                        MediaInfo(320, 240, 10, "vp9", 1))
    parsed, receipt = evaluation.prepare(path, profile)
    assert parsed.dataset == "test" and len(receipt["cases"]) == 1
    (tmp_path / "query").write_bytes(b"reference1")
    with pytest.raises(SpikeError) as error:
        evaluation.prepare(path, profile)
    assert error.value.code == "DATASET_LEAKAGE"
    (tmp_path / "query").write_bytes(b"query")
    suite["dataset"] = "calibration"
    path.write_text(json.dumps(suite))
    with pytest.raises(SpikeError) as error:
        evaluation.prepare(path, profile)
    assert error.value.code == "DATASET_MISMATCH"


def test_retained_exclusion_hashes_reject_leakage_after_raw_cleanup(tmp_path, monkeypatch):
    path, profile, suite = private_suite(tmp_path)
    monkeypatch.setattr("facetrack_ml.capture.probe", lambda *a, **k:
                        MediaInfo(320, 240, 10, "vp9", 1))
    suite["excluded_media_sha256"] = [digest(tmp_path / name)
                                       for name in suite["excluded_videos"]]
    for name in suite["excluded_videos"]:
        (tmp_path / name).unlink()
    suite["excluded_videos"] = []
    path.write_text(json.dumps(suite))
    _, receipt = evaluation.prepare(path, profile)
    assert len(receipt["excluded_media_sha256"]) == 2
    (tmp_path / "query").write_bytes(b"reference1")
    with pytest.raises(SpikeError) as error:
        evaluation.prepare(path, profile)
    assert error.value.code == "DATASET_LEAKAGE"


def test_evaluation_preserves_failure_and_does_not_claim_acceptance(tmp_path, monkeypatch):
    path, profile, _ = private_suite(tmp_path)
    monkeypatch.setattr("facetrack_ml.capture.probe", lambda *a, **k:
                        MediaInfo(320, 240, 10, "vp9", 1))
    manifest = tmp_path / "manifest.json"
    manifest.write_text("{}")
    def failed_process(*args, **kwargs):
        return subprocess.CompletedProcess([], 2, b"", b"private native error")
    monkeypatch.setattr(evaluation.subprocess, "run", failed_process)
    out = tmp_path / "results" / "test.json"
    result = evaluation.evaluate(path, profile, manifest, tmp_path, out, 3)
    report = json.loads(out.read_text())
    assert result["status"] == "incomplete_or_failed"
    assert len(report["cases"][0]["runs"]) == 3
    assert "private native error" not in out.read_text()
    assert out.with_suffix(".lock.json").exists()
    with pytest.raises(SpikeError) as error:
        evaluation.evaluate(path, profile, manifest, tmp_path, out, 3)
    assert error.value.code == "EVALUATION_EXISTS"


def test_comparison_reports_false_matches_and_misses():
    result = evaluation.compare({"proposals": [{"participant_id": "p02"}]}, ["p01"])
    assert result["false_presence_proposals"] == ["p02"]
    assert result["missed_present_identities"] == ["p01"]
    assert not result["identity_set_matches"]


def test_changed_quality_floor_requires_new_profile_and_template_set(tmp_path, monkeypatch):
    manifest = SimpleNamespace(model_dump=lambda: {"synthetic": "profile contract only"})
    monkeypatch.setattr("facetrack_ml.cli.load_manifest", lambda path: manifest)
    args = parser().parse_args(["profile", "--manifest", "unused.json", "--out",
                                str(tmp_path / "profile.json"), "--calibration-id", "synthetic",
                                "--identity-threshold", "0.8", "--minimum-margin", "0.1",
                                "--enrollment-consistency", "0.7"])
    execute(args)
    original = Profile.model_validate_json(args.out.read_text())
    assert original.blur_variance == 40  # preserve the current default
    args.out = tmp_path / "changed-profile.json"
    args.blur_variance = 25  # synthetic experimental setting, not a recommended real value
    execute(args)
    changed = Profile.model_validate_json(args.out.read_text())
    assert changed.blur_variance == 25
    store = TemplateStore(tmp_path / "templates")
    vectors = np.zeros((3, 512), np.float32)
    vectors[:, 0] = 1
    original_hash = canonical_hash(original.model_dump())
    store.save("p01", vectors, original.model_hash, original_hash)
    store.save("p02", vectors, original.model_hash, original_hash)
    with pytest.raises(SpikeError) as error:
        store.load(["p01", "p02"], changed.model_hash, canonical_hash(changed.model_dump()))
    assert error.value.code == "TEMPLATE_VERSION_MISMATCH"
    with pytest.raises(SpikeError) as error:
        execute(args)
    assert error.value.code == "PROFILE_EXISTS"


def test_complete_synthetic_suite_still_requires_human_review(tmp_path, monkeypatch):
    path, profile, suite = private_suite(tmp_path)
    scenarios = [("both_known", ["p01", "p02"]), ("one_absent", ["p01"]),
                 ("unknown_only", []), ("mixed_unknown", ["p01"]),
                 ("variation", ["p01", "p02"]), ("no_face", [])]
    suite["cases"] = []
    for scenario, expected in scenarios:
        (tmp_path / scenario).write_bytes(scenario.encode())
        (tmp_path / f"{scenario}.json").write_text(json.dumps(metadata()))
        suite["cases"].append({"case_id": scenario, "scenario": scenario, "video": scenario,
                                "metadata": f"{scenario}.json", "expected_present": expected})
    path.write_text(json.dumps(suite))
    monkeypatch.setattr("facetrack_ml.capture.probe", lambda *a, **k:
                        MediaInfo(320, 240, 10, "vp9", 1))
    calls = []

    def fake_process(command, **kwargs):
        assert (tmp_path / "report.lock.json").exists()  # freeze BEFORE test inference
        scenario = Path(command[command.index("recognize") + 1]).name
        calls.append(scenario)
        expected = dict(scenarios)[scenario]
        return subprocess.CompletedProcess(command, 0, json.dumps({
            "proposals": [{"participant_id": p} for p in expected], "unknown_observations": 0,
            "quality": {"synthetic": True}, "timings": {"cold_start_ms": 1}}).encode(), b"")

    from pathlib import Path
    monkeypatch.setattr(evaluation.subprocess, "run", fake_process)
    manifest = tmp_path / "manifest.json"
    manifest.write_text("{}")
    out = tmp_path / "report.json"
    report = evaluation.evaluate(path, profile, manifest, tmp_path, out, 3)
    assert len(calls) == 18
    assert report["status"] == "checks_passed_pending_human_review"
    assert not report["missing_scenarios"]
