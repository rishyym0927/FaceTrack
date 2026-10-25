"""Pipeline control-flow tests with explicit synthetic observations, not accuracy evidence."""

from pathlib import Path

import numpy as np
import pytest
from facetrack_ml.config import Profile, canonical_hash
from facetrack_ml.media import MediaInfo
from facetrack_ml.pipeline import Pipeline
from facetrack_ml.runtime import CANONICAL, Face
from facetrack_ml.store import TemplateStore


def unit(index):
    vector = np.zeros(512, np.float32)
    vector[index] = 1
    return vector


class MathematicalRuntime:
    cold_start_ms = 12.0


def test_pipeline_enrol_then_known_unknown_absent_and_repeat(monkeypatch, tmp_path):
    model = "a" * 64
    profile = Profile(model_hash=model, calibration_id="synthetic-control-flow-only",
                      identity_threshold=0.8, minimum_margin=0.1, enrollment_consistency=0.7)
    store = TemplateStore(tmp_path / "templates")
    pipeline = Pipeline(MathematicalRuntime(), profile, model)
    path = tmp_path / "synthetic-bytes.webm"
    path.write_bytes(b"hash fixture only; observe is explicitly mocked in this test")

    def fake_observe(video: Path, *, enrollment: bool):
        if enrollment:
            entries = [(100, unit(0)), (700, unit(0)), (1300, unit(0))]
        else:
            entries = [(100, unit(0)), (700, unit(0)), (100, unit(2)), (700, unit(2))]
        return entries, dict.fromkeys(["decoding_ms", "detection_ms", "embedding_ms",
                                      "matching_ms"], 1.0), {"synthetic": True}, MediaInfo(
                                          320, 240, 15, "vp9", 1)

    monkeypatch.setattr(pipeline, "observe", fake_observe)
    enrolled = pipeline.enrol(path, "p01", store)
    assert enrolled["template_count"] == 3
    store.save("p02", np.stack([unit(1)] * 3), model, canonical_hash(profile.model_dump()))
    first = pipeline.recognize(path, ["p01", "p02"], store)
    second = pipeline.recognize(path, ["p01", "p02"], store)
    assert first["proposals"] == second["proposals"]
    assert first["proposals"][0]["participant_id"] == "p01"
    assert first["unknown_observations"] == 2
    assert first["unassessed"] == ["p02"]
    assert b'"vectors"' not in store.path("p01").read_bytes()
    assert "vectors" not in str(first)


def test_no_face_remains_unassessed_and_duplicate_pixels_are_skipped(monkeypatch, tmp_path):
    model = "a" * 64
    profile = Profile(model_hash=model, calibration_id="synthetic-no-face",
                      identity_threshold=0.8, minimum_margin=0.1, enrollment_consistency=0.7)
    store = TemplateStore(tmp_path / "templates")
    for person, index in (("p01", 0), ("p02", 1)):
        store.save(person, np.stack([unit(index)] * 3), model,
                   canonical_hash(profile.model_dump()))

    class EmptyRuntime:
        cold_start_ms = 0.0
        calls = 0

        def detect(self, *_):
            self.calls += 1
            return []

    runtime = EmptyRuntime()
    pipeline = Pipeline(runtime, profile, model)
    frame = np.zeros((112, 112, 3), np.uint8)
    monkeypatch.setattr("facetrack_ml.pipeline.probe", lambda *_args, **_kwargs:
                        MediaInfo(112, 112, 2, "vp9", 1))
    monkeypatch.setattr("facetrack_ml.pipeline.sampled_frames", lambda *_args:
                        iter([(100, frame), (700, frame)]))
    path = tmp_path / "no-face.webm"
    path.write_bytes(b"synthetic control-flow fixture")
    result = pipeline.recognize(path, ["p01", "p02"], store)
    assert result["proposals"] == [] and result["unassessed"] == ["p01", "p02"]
    assert result["quality"]["duplicate_frames"] == 1 and runtime.calls == 1


@pytest.mark.xfail(strict=True, reason="Frozen pipeline aborts clip on one degenerate alignment")
def test_bad_face_alignment_should_not_discard_other_usable_faces(monkeypatch, tmp_path):
    """Reproduced limitation; fix in a separately versioned inference candidate."""
    model = "a" * 64
    profile = Profile(model_hash=model, calibration_id="synthetic-degenerate-landmarks",
                      identity_threshold=0.8, minimum_margin=0.1, enrollment_consistency=0.7)

    class TwoFaceRuntime:
        cold_start_ms = 0.0

        def detect(self, *_):
            box = np.array([0, 0, 112, 112], dtype=np.float32)
            return [Face(box, np.full((5, 2), 50, np.float32), 0.99),
                    Face(box, CANONICAL.copy(), 0.99)]

        def embed(self, crops):
            return np.stack([unit(0)] * len(crops))

    pipeline = Pipeline(TwoFaceRuntime(), profile, model)
    frame = np.random.default_rng(1).integers(0, 256, (112, 112, 3), dtype=np.uint8)
    monkeypatch.setattr("facetrack_ml.pipeline.probe", lambda *_args, **_kwargs:
                        MediaInfo(112, 112, 2, "vp9", 1))
    monkeypatch.setattr("facetrack_ml.pipeline.sampled_frames", lambda *_args:
                        iter([(100, frame)]))
    observations, _, stats, _ = pipeline.observe(tmp_path / "synthetic.webm", enrollment=False)
    assert len(observations) == 1 and stats["quality_rejects"] == 1
