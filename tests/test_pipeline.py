"""Pipeline control-flow tests with explicit synthetic observations, not accuracy evidence."""

from pathlib import Path

import numpy as np
from facetrack_ml.config import Profile, canonical_hash
from facetrack_ml.media import MediaInfo
from facetrack_ml.pipeline import Pipeline
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
