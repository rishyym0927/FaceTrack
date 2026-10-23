from __future__ import annotations

import time
from dataclasses import dataclass
from pathlib import Path

import cv2
import numpy as np
import onnxruntime as ort

from .config import ModelManifest, Profile, load_manifest
from .errors import SpikeError

ort.disable_telemetry_events()

CANONICAL = np.array([[38.2946, 51.6963], [73.5318, 51.5014], [56.0252, 71.7366],
                      [41.5493, 92.3655], [70.7299, 92.2041]], dtype=np.float32)


def normalize(vector: np.ndarray) -> np.ndarray:
    vector = np.asarray(vector, dtype=np.float32)
    norm = np.linalg.norm(vector, axis=-1, keepdims=True)
    if not np.isfinite(vector).all() or not np.isfinite(norm).all() or np.any(norm < 1e-8):
        raise SpikeError("INVALID_EMBEDDING", "Embedding must be finite with nonzero norm.")
    return vector / norm


@dataclass
class Face:
    box: np.ndarray
    landmarks: np.ndarray
    confidence: float


def nms(boxes: np.ndarray, scores: np.ndarray, threshold: float) -> list[int]:
    order = scores.argsort()[::-1]
    selected = []
    while order.size:
        i = int(order[0])
        selected.append(i)
        rest = order[1:]
        if not rest.size:
            break
        a, b = boxes[i], boxes[rest]
        intersection = np.maximum(0, np.minimum(a[2:], b[:, 2:]) -
                                  np.maximum(a[:2], b[:, :2])).prod(axis=1)
        area_a = np.maximum(0, a[2:] - a[:2]).prod()
        area_b = np.maximum(0, b[:, 2:] - b[:, :2]).prod(axis=1)
        iou = intersection / np.maximum(area_a + area_b - intersection, 1e-8)
        order = rest[iou <= threshold]
    return selected


def align(frame: np.ndarray, landmarks: np.ndarray) -> np.ndarray:
    if landmarks.shape != (5, 2) or not np.isfinite(landmarks).all():
        raise SpikeError("INVALID_LANDMARKS", "Expected five finite facial landmarks.")
    matrix, _ = cv2.estimateAffinePartial2D(landmarks.astype(np.float32), CANONICAL,
                                         method=cv2.LMEDS)
    if matrix is None:
        raise SpikeError("ALIGNMENT_FAILED", "Cannot align detected facial landmarks.")
    return cv2.warpAffine(frame, matrix, (112, 112), borderValue=0)


def quality(frame: np.ndarray, face: Face, profile: Profile) -> bool:
    h, w = frame.shape[:2]
    x1, y1, x2, y2 = face.box.astype(int)
    if x1 < 0 or y1 < 0 or x2 > w or y2 > h:
        return False
    if min(x2 - x1, y2 - y1) < profile.min_face_pixels:
        return False
    if (not np.isfinite(face.landmarks).all() or np.any(face.landmarks < [x1, y1])
            or np.any(face.landmarks > [x2, y2])):
        return False
    gray = cv2.cvtColor(frame[y1:y2, x1:x2], cv2.COLOR_BGR2GRAY)
    return bool(5 < gray.mean() < 250 and
                cv2.Laplacian(gray, cv2.CV_64F).var() >= profile.blur_variance)


class Runtime:
    """Explicit SCRFD 3-stride/2-anchor/landmark + ArcFace 112px ONNX adapter.

    Model outputs must be listed as scores(strides 8,16,32), boxes, then landmarks.
    This contract deliberately refuses unsupported heads rather than guessing.
    """

    def __init__(self, manifest_path: Path):
        started = time.perf_counter()
        self.manifest: ModelManifest = load_manifest(manifest_path)
        m = self.manifest
        options = ort.SessionOptions()
        options.intra_op_num_threads = 4
        options.inter_op_num_threads = 1
        self.detector = ort.InferenceSession(str(manifest_path.parent / m.detector.file),
                                            sess_options=options,
                                            providers=["CPUExecutionProvider"])
        self.recognizer = ort.InferenceSession(str(manifest_path.parent / m.recognizer.file),
                                              sess_options=options,
                                              providers=["CPUExecutionProvider"])
        if len(m.detector.output_names) != 9 or len(m.recognizer.output_names) != 1:
            raise SpikeError("MODEL_CONTRACT_MISMATCH", "Expected nine SCRFD heads and one embedding.")
        for session, artifact, shape in [(self.detector, m.detector, (1, 3, 640, 640)),
                                          (self.recognizer, m.recognizer, (1, 3, 112, 112))]:
            inputs = session.get_inputs()
            if len(inputs) != 1 or inputs[0].name != artifact.input_name:
                raise SpikeError("MODEL_CONTRACT_MISMATCH", "Unexpected model input contract.")
            if inputs[0].type != "tensor(float)" or len(inputs[0].shape) != 4:
                raise SpikeError("MODEL_CONTRACT_MISMATCH", "Expected float32 NCHW inputs.")
            for actual, expected in zip(inputs[0].shape, shape, strict=True):
                if isinstance(actual, int) and actual != expected:
                    raise SpikeError("MODEL_CONTRACT_MISMATCH", "Unsupported model dimensions.")
            if set(artifact.output_names) != {o.name for o in session.get_outputs()}:
                raise SpikeError("MODEL_CONTRACT_MISMATCH", "Unexpected model output names.")
        # Real provider execution, not merely listing installed providers.
        self.detect(np.zeros((640, 640, 3), np.uint8), 0.6, 0.4)
        self.embed([np.zeros((112, 112, 3), np.uint8)])
        self.cold_start_ms = (time.perf_counter() - started) * 1000

    def detect(self, frame: np.ndarray, confidence: float, iou: float) -> list[Face]:
        h, w = frame.shape[:2]
        ratio = min(640 / w, 640 / h)
        resized_w, resized_h = max(1, int(w * ratio)), max(1, int(h * ratio))
        image = np.zeros((640, 640, 3), np.uint8)
        image[:resized_h, :resized_w] = cv2.resize(frame, (resized_w, resized_h))
        m = self.manifest
        blob = cv2.dnn.blobFromImage(image, 1 / m.detector_scale, (640, 640),
                                    (m.detector_mean,) * 3, swapRB=True)
        outputs = self.detector.run(m.detector.output_names, {m.detector.input_name: blob})
        all_boxes, all_points, all_scores = [], [], []
        for index, stride in enumerate((8, 16, 32)):
            scores = np.asarray(outputs[index]).reshape(-1)
            boxes = np.asarray(outputs[index + 3]).reshape(-1, 4) * stride
            points = np.asarray(outputs[index + 6]).reshape(-1, 5, 2) * stride
            grid = np.stack(np.mgrid[:640 // stride, :640 // stride][::-1], axis=-1)
            centers = np.repeat(grid.reshape(-1, 2) * stride, 2, axis=0)
            if (len(scores) != len(centers) or len(boxes) != len(centers)
                    or len(points) != len(centers) or not np.isfinite(scores).all()
                    or not np.isfinite(boxes).all() or not np.isfinite(points).all()):
                raise SpikeError("MODEL_CONTRACT_MISMATCH", "Invalid SCRFD head shape or values.")
            decoded = np.concatenate((centers - boxes[:, :2], centers + boxes[:, 2:]), axis=1)
            selected = scores >= confidence
            all_boxes.append(decoded[selected] / ratio)
            all_points.append((points + centers[:, None, :])[selected] / ratio)
            all_scores.append(scores[selected])
        boxes, points, scores = map(np.concatenate, (all_boxes, all_points, all_scores))
        return [Face(boxes[i], points[i], float(scores[i])) for i in nms(boxes, scores, iou)]

    def embed(self, crops: list[np.ndarray]) -> np.ndarray:
        m = self.manifest
        # Fixed-batch-one artifacts are supported without silently changing their contract.
        results = []
        for crop in crops:
            blob = cv2.dnn.blobFromImage(crop, 1 / m.recognizer_scale, (112, 112),
                                        (m.recognizer_mean,) * 3, swapRB=True)
            output = self.recognizer.run(m.recognizer.output_names,
                                         {m.recognizer.input_name: blob})[0]
            if np.asarray(output).shape != (1, 512):
                raise SpikeError("MODEL_CONTRACT_MISMATCH", "Expected a 512D embedding.")
            results.append(normalize(output[0]))
        return np.stack(results) if results else np.empty((0, 512), np.float32)
