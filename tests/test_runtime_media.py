import json
import subprocess
from types import SimpleNamespace

import numpy as np
import onnx
import pytest
from facetrack_ml.config import canonical_hash, digest, load_manifest
from facetrack_ml.errors import SpikeError
from facetrack_ml.media import executable, probe, sampled_frames
from facetrack_ml.runtime import CANONICAL, Runtime, align
from onnx import TensorProto, helper, numpy_helper


def synthetic_model(path, shape, outputs):
    """Constant mathematical fixtures only. These are NOT face recognition models."""
    nodes = [helper.make_node("Constant", [], [name],
                              value=numpy_helper.from_array(array, name + "_value"))
             for name, array in outputs.items()]
    graph = helper.make_graph(nodes, "synthetic-contract-fixture",
                              [helper.make_tensor_value_info("input", TensorProto.FLOAT, shape)],
                              [helper.make_tensor_value_info(name, TensorProto.FLOAT, array.shape)
                               for name, array in outputs.items()])
    model = helper.make_model(graph, opset_imports=[helper.make_opsetid("", 17)], ir_version=9)
    onnx.save(model, path)


def fixture_manifest(tmp_path):
    outputs = {}
    for label, channels in [("score", 1), ("box", 4), ("kps", 10)]:
        for stride in [8, 16, 32]:
            outputs[f"{label}{stride}"] = np.zeros(((640 // stride) ** 2 * 2, channels), np.float32)
    synthetic_model(tmp_path / "detector.onnx", [1, 3, 640, 640], outputs)
    vector = np.zeros((1, 512), np.float32)
    vector[0, 0] = 1
    synthetic_model(tmp_path / "recognizer.onnx", [1, 3, 112, 112], {"embedding": vector})
    evidence = tmp_path / "evidence.txt"
    evidence.write_text("Synthetic mathematical test fixtures authored here; no biometric weights.")
    manifest = {"release_id": "synthetic-test-only", "detector": {
        "file": "detector.onnx", "sha256": digest(tmp_path / "detector.onnx"),
        "source_url": "synthetic:test-only", "input_name": "input", "output_names": list(outputs)},
        "recognizer": {"file": "recognizer.onnx", "sha256": digest(tmp_path / "recognizer.onnx"),
                       "source_url": "synthetic:test-only", "input_name": "input",
                       "output_names": ["embedding"]}, "license": {
            "status": "approved", "intended_use": "local_poc", "evidence_file": "evidence.txt",
            "evidence_sha256": digest(evidence), "reviewed_by": "automated-test-fixture",
            "reviewed_at": "2026-10-22", "permitted_uses": ["local_poc"]}}
    path = tmp_path / "manifest.json"
    path.write_text(json.dumps(manifest))
    return path, manifest


def test_unapproved_example_cannot_load():
    from pathlib import Path
    with pytest.raises(SpikeError) as error:
        load_manifest(Path("models/manifest.example.json"))
    assert error.value.code == "MODEL_PERMISSION_REQUIRED"


def test_real_onnx_execution_against_synthetic_contract(tmp_path):
    path, _ = fixture_manifest(tmp_path)
    runtime = Runtime(path)
    assert runtime.detect(np.zeros((720, 1280, 3), np.uint8), 0.6, 0.4) == []
    embeddings = runtime.embed([np.zeros((112, 112, 3), np.uint8)] * 2)
    assert embeddings.shape == (2, 512)
    np.testing.assert_allclose(np.linalg.norm(embeddings, axis=1), 1)
    assert runtime.cold_start_ms > 0


def test_model_and_evidence_hashes_are_enforced(tmp_path):
    path, manifest = fixture_manifest(tmp_path)
    before = canonical_hash(manifest)
    (tmp_path / "evidence.txt").write_text("changed")
    with pytest.raises(SpikeError) as error:
        load_manifest(path)
    assert error.value.code == "LICENSE_EVIDENCE_MISMATCH"
    assert before != canonical_hash({**manifest, "release_id": "changed"})


def test_alignment_identity_transform():
    frame = np.random.default_rng(0).integers(0, 256, (112, 112, 3), dtype=np.uint8)
    np.testing.assert_allclose(align(frame, CANONICAL), frame, atol=0)


def test_rgb_normalization_and_top_left_padding_contract():
    """Golden pixel arithmetic with fake sessions; no claim about real model quality."""
    class Session:
        def __init__(self, outputs):
            self.outputs = outputs
            self.blob = None

        def run(self, names, inputs):
            self.blob = inputs["input"].copy()
            return self.outputs

    outputs = [np.zeros(((640 // stride) ** 2 * 2, channels), np.float32)
               for channels in (1, 4, 10) for stride in (8, 16, 32)]
    runtime = Runtime.__new__(Runtime)
    artifact = SimpleNamespace(input_name="input", output_names=[])
    runtime.manifest = SimpleNamespace(detector=artifact, recognizer=artifact,
                                       detector_mean=127.5, detector_scale=128.0,
                                       recognizer_mean=127.5, recognizer_scale=127.5)
    runtime.detector = Session(outputs)
    vector = np.zeros((1, 512), np.float32)
    vector[0, 0] = 1
    runtime.recognizer = Session([vector])
    bgr = np.full((320, 640, 3), [10, 100, 240], np.uint8)
    assert runtime.detect(bgr, 0.6, 0.4) == []
    np.testing.assert_allclose(runtime.detector.blob[0, :, 100, 100],
                               (np.array([240, 100, 10]) - 127.5) / 128, atol=1e-7)
    np.testing.assert_allclose(runtime.detector.blob[0, :, 500, 100], -127.5 / 128)
    runtime.embed([bgr[:112, :112]])
    np.testing.assert_allclose(runtime.recognizer.blob[0, :, 50, 50],
                               (np.array([240, 100, 10]) - 127.5) / 127.5, atol=1e-7)


@pytest.mark.parametrize("extension,codec", [("mp4", "libx264"), ("webm", "libvpx-vp9")])
def test_actual_ffmpeg_container_probe_and_sampling(tmp_path, extension, codec):
    path = tmp_path / f"synthetic-nonbiometric.{extension}"
    subprocess.run([executable("ffmpeg"), "-v", "error", "-f", "lavfi", "-i",
                    "testsrc2=size=320x240:rate=15:duration=2", "-an", "-c:v", codec,
                    "-pix_fmt", "yuv420p", str(path)], check=True, timeout=30)
    info = probe(path)
    timings = {}
    frames = list(sampled_frames(path, info, 12, timings))
    assert len(frames) == 12
    assert frames[0][1].shape == (240, 320, 3)
    assert frames[-1][0] > frames[0][0]
    assert timings["decoding_ms"] > 0


def test_corrupt_media_rejected(tmp_path):
    path = tmp_path / "corrupt.mp4"
    path.write_bytes(b"not-video")
    with pytest.raises(SpikeError) as error:
        probe(path)
    assert error.value.code == "INVALID_MEDIA"


@pytest.mark.parametrize("packet_times,valid", [
    ([round(i / 30, 3) for i in range(450)], True),
    ([round(i / 120, 6) for i in range(1800)], False),
    ([0, 0, 1], False),
    ([0, 16], False),
    ([float("nan"), 1], False),
    ([i / 120 for i in range(1801)], False),
])
def test_chrome_missing_average_rate_uses_bounded_timestamps(tmp_path, monkeypatch,
                                                          packet_times, valid):
    """Browser-style probe responses; no biometric fixture is stored in tests."""
    video = tmp_path / "synthetic.webm"
    video.write_bytes(b"probe subprocess mocked")

    def fake_probe(command, **kwargs):
        if "-show_packets" in command:
            assert command[command.index("-read_intervals") + 1] == "%+#1801"
            data = {"packets": [{"pts_time": str(stamp)} for stamp in packet_times]}
        else:
            data = {"streams": [{"codec_type": "video", "codec_name": "vp9",
                                  "width": 1280, "height": 720, "avg_frame_rate": "0/0",
                                  "r_frame_rate": "1000/1"}], "format": {"duration": "15"}}
        return subprocess.CompletedProcess(command, 0, json.dumps(data).encode())

    monkeypatch.setattr("facetrack_ml.media.subprocess.run", fake_probe)
    if valid:
        assert probe(video).codec == "vp9"
    else:
        with pytest.raises(SpikeError) as error:
            probe(video)
        assert error.value.code == "INVALID_MEDIA"
