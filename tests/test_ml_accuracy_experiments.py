import json
from pathlib import Path
from types import SimpleNamespace

import cv2
import numpy as np
from facetrack_ml.runtime import Face

from experiments.ml_accuracy import (
    CandidateConfig,
    CandidateQualityGate,
    DetectorFrame,
    FivePointYawResearch,
    MultiScaleScrfd,
    safe_align,
)
from experiments.ml_accuracy.harness import (
    AttendanceOutcome,
    attendance_metrics,
    build_digiface_manifest,
    write_aggregate_results,
)


def face(box=(20, 20, 120, 120)):
    return Face(
        np.asarray(box, dtype=np.float32),
        np.asarray([[45, 50], [90, 50], [68, 70], [50, 95], [85, 95]], dtype=np.float32),
        0.9,
    )


def test_clahe_is_deterministic_and_preserves_recognition_pixels():
    image = np.tile(np.arange(160, dtype=np.uint8), (160, 1))
    image = cv2.cvtColor(image, cv2.COLOR_GRAY2BGR)
    first = DetectorFrame.prepare(image, clahe=True)
    second = DetectorFrame.prepare(image, clahe=True)
    assert np.array_equal(first.recognition, image)
    assert np.array_equal(first.detector, second.detector)
    assert not np.shares_memory(first.detector, first.recognition)


def test_quality_reasons_and_uncalibrated_yaw_refuses_degrees():
    image = np.full((160, 160, 3), 100, np.uint8)
    gate = CandidateQualityGate(CandidateConfig(blur_variance=0, contrast_std=1))
    assert gate.reject_reason(image, face()) == "contrast"
    raw = FivePointYawResearch.raw_asymmetry(face().landmarks)
    assert -1 <= raw <= 1
    try:
        FivePointYawResearch.calibrated_degrees(raw, slope=None, intercept=None)
    except ValueError:
        pass
    else:
        raise AssertionError("Unvalidated yaw proxy was reported as degrees.")


def test_safe_alignment_rejects_only_one_crop():
    counters = {}
    bad = face()
    bad.landmarks[:] = 1
    assert safe_align(np.zeros((160, 160, 3), np.uint8), bad, counters) is None
    assert counters == {"alignment_rejects": 1}


def test_multiscale_global_nms_maps_duplicate_boxes(monkeypatch):
    manifest = SimpleNamespace(
        detector_scale=128.0,
        detector_mean=127.5,
        detector=SimpleNamespace(
            input_name="input", output_names=[str(i) for i in range(9)]
        ),
    )
    detector = MultiScaleScrfd(SimpleNamespace(), manifest)
    monkeypatch.setattr(detector, "_at", lambda frame, size, confidence: [face()])
    result = detector.detect(np.zeros((200, 200, 3), np.uint8), 0.6, 0.4)
    assert len(result) == 1


def test_candidate_matrix_labels_synthetic_results_and_keeps_others_unmeasured():
    data = json.loads(Path("experiments/ml_accuracy/candidates.json").read_text())
    assert len(data["variants"]) == 8
    assert "Not measured yet" in data["result_status"]
    measured = [v for v in data["variants"] if "synthetic_result" in v]
    assert len(measured) == 4
    assert all("SYNTHETIC" in v["synthetic_result"]["basis"] for v in measured)
    assert all(v["synthetic_result"]["wrong_present_marks"] == 0 for v in measured)
    assert all("synthetic_result" not in v for v in data["variants"] if v.get("blocked"))


def test_digiface_manifest_is_deterministic_and_disjoint():
    index = {f"person-{i:03d}": [f"person-{i:03d}/{j}.png" for j in range(5)] for i in range(205)}
    first = build_digiface_manifest(index)
    second = build_digiface_manifest(index)
    assert first == second
    assert len(first["identities"]) == 200
    assert sum(x["split"] == "calibration" for x in first["identities"]) == 80
    assert len(first["scenes"]) == 60
    assert all(
        {asset["asset_id"] for asset in x["enrolment"]}.isdisjoint(
            asset["asset_id"] for asset in x["queries"]
        )
        for x in first["identities"]
    )
    serialized = json.dumps(first)
    assert "person-" not in serialized


def test_attendance_metrics_keep_absent_and_unknown_failures_visible():
    result = attendance_metrics(
        [
            AttendanceOutcome("v1", "both_known", "known", True, True, True, True),
            AttendanceOutcome("v1", "one_absent", "absent", False, True, True, True),
            AttendanceOutcome("v2", "unknown_only", "unknown", False, True, False, True),
            AttendanceOutcome("v3", "both_known", "miss", True, False, True, True),
            AttendanceOutcome("v4", "position_scale", "covered", True, False, True, False),
        ]
    )
    assert result["unknown_false_identifications"] == 1
    assert result["absent_false_presence"] == 2
    assert result["coverage"] == 0.8


def test_aggregate_outputs_exclude_identity_rows(tmp_path):
    rows = [AttendanceOutcome("v1", "both_known", "private-id", True, True, True, True)]
    json_path, csv_path = write_aggregate_results(rows, tmp_path)
    assert "private-id" not in json_path.read_text()
    assert "private-id" not in csv_path.read_text()
    assert json.loads(json_path.read_text())["overall"]["proposed_present_recall"] == 1.0
