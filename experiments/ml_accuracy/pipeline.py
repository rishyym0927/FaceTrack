"""Composable detector experiments isolated from the receipt-pinned baseline.

This module deliberately has no product wiring. Candidate results must be emitted to a
separate result directory and approved as a new model/profile release before adoption.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol

import cv2
import numpy as np
from facetrack_ml.errors import SpikeError
from facetrack_ml.runtime import Face, align, nms


@dataclass(frozen=True)
class CandidateConfig:
    input_sizes: tuple[int, ...] = (640, 960)
    confidence: float = 0.6
    nms_iou: float = 0.4
    min_face_pixels: int = 80
    blur_variance: float = 80.0
    contrast_std: float | None = None
    detector_clahe: bool = False
    pose_raw_limit: float | None = None


@dataclass(frozen=True)
class DetectorFrame:
    """Separate detector pixels from the unmodified recognition source."""

    detector: np.ndarray
    recognition: np.ndarray

    @classmethod
    def prepare(cls, frame: np.ndarray, *, clahe: bool) -> "DetectorFrame":
        original = np.asarray(frame)
        if not clahe:
            return cls(original, original)
        lab = cv2.cvtColor(original, cv2.COLOR_BGR2LAB)
        luminance, a, b = cv2.split(lab)
        corrected = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8)).apply(luminance)
        detector = cv2.cvtColor(cv2.merge((corrected, a, b)), cv2.COLOR_LAB2BGR)
        return cls(detector, original)


class ScrfdSession(Protocol):
    def run(self, output_names: list[str], inputs: dict[str, np.ndarray]) -> list[np.ndarray]: ...


class MultiScaleScrfd:
    """Runs one SCRFD session at each configured resolution, then performs global NMS."""

    def __init__(self, session: ScrfdSession, manifest, sizes: tuple[int, ...] = (640, 960)):
        if not sizes or any(size <= 0 or size % 32 for size in sizes):
            raise ValueError("SCRFD input sizes must be positive multiples of 32.")
        self.session, self.manifest, self.sizes = session, manifest, sizes

    def _at(self, frame: np.ndarray, size: int, confidence: float) -> list[Face]:
        h, w = frame.shape[:2]
        ratio = min(size / w, size / h)
        resized_w, resized_h = max(1, int(w * ratio)), max(1, int(h * ratio))
        image = np.zeros((size, size, 3), np.uint8)
        image[:resized_h, :resized_w] = cv2.resize(frame, (resized_w, resized_h))
        m = self.manifest
        blob = cv2.dnn.blobFromImage(
            image, 1 / m.detector_scale, (size, size), (m.detector_mean,) * 3, swapRB=True
        )
        outputs = self.session.run(m.detector.output_names, {m.detector.input_name: blob})
        faces: list[Face] = []
        for index, stride in enumerate((8, 16, 32)):
            scores = np.asarray(outputs[index]).reshape(-1)
            boxes = np.asarray(outputs[index + 3]).reshape(-1, 4) * stride
            points = np.asarray(outputs[index + 6]).reshape(-1, 5, 2) * stride
            grid = np.stack(np.mgrid[: size // stride, : size // stride][::-1], axis=-1)
            centers = np.repeat(grid.reshape(-1, 2) * stride, 2, axis=0)
            if not (len(scores) == len(boxes) == len(points) == len(centers)):
                raise SpikeError("MODEL_CONTRACT_MISMATCH", "Invalid dynamic SCRFD output grid.")
            keep = scores >= confidence
            decoded = np.concatenate((centers - boxes[:, :2], centers + boxes[:, 2:]), axis=1)
            for box, landmarks, score in zip(
                decoded[keep] / ratio,
                (points + centers[:, None, :])[keep] / ratio,
                scores[keep],
                strict=True,
            ):
                faces.append(Face(box, landmarks, float(score)))
        return faces

    def detect(self, frame: np.ndarray, confidence: float, iou: float) -> list[Face]:
        candidates = [face for size in self.sizes for face in self._at(frame, size, confidence)]
        if not candidates:
            return []
        boxes = np.stack([f.box for f in candidates])
        scores = np.asarray([f.confidence for f in candidates], dtype=np.float32)
        return [candidates[i] for i in nms(boxes, scores, iou)]


class FivePointYawResearch:
    """Uncalibrated landmark asymmetry proxy; it is not an angle until BIWI validation."""

    @staticmethod
    def raw_asymmetry(landmarks: np.ndarray) -> float:
        points = np.asarray(landmarks, dtype=np.float64)
        if points.shape != (5, 2) or not np.isfinite(points).all():
            raise ValueError("Five finite landmarks are required.")
        left_eye, right_eye, nose = points[:3]
        left = np.linalg.norm(nose - left_eye)
        right = np.linalg.norm(right_eye - nose)
        scale = max(left + right, 1e-8)
        return float((right - left) / scale)

    @staticmethod
    def calibrated_degrees(raw: float, *, slope: float | None, intercept: float | None) -> float:
        if slope is None or intercept is None:
            raise ValueError("BIWI calibration is required before reporting degrees.")
        return slope * raw + intercept


class CandidateQualityGate:
    def __init__(self, config: CandidateConfig):
        self.config = config

    def reject_reason(self, frame: np.ndarray, face: Face) -> str | None:
        h, w = frame.shape[:2]
        x1, y1, x2, y2 = face.box.astype(int)
        if x1 < 0 or y1 < 0 or x2 > w or y2 > h or x2 <= x1 or y2 <= y1:
            return "size"
        if min(x2 - x1, y2 - y1) < self.config.min_face_pixels:
            return "size"
        points = np.asarray(face.landmarks)
        if points.shape != (5, 2) or not np.isfinite(points).all():
            return "landmarks"
        if np.any(points < [x1, y1]) or np.any(points > [x2, y2]):
            return "landmarks"
        gray = cv2.cvtColor(frame[y1:y2, x1:x2], cv2.COLOR_BGR2GRAY)
        if not 5 < float(gray.mean()) < 250:
            return "exposure"
        if cv2.Laplacian(gray, cv2.CV_64F).var() < self.config.blur_variance:
            return "blur"
        if self.config.contrast_std is not None and float(gray.std()) < self.config.contrast_std:
            return "contrast"
        if self.config.pose_raw_limit is not None:
            if abs(FivePointYawResearch.raw_asymmetry(points)) > self.config.pose_raw_limit:
                return "pose"
        return None


def safe_align(frame: np.ndarray, face: Face, counters: dict[str, int]) -> np.ndarray | None:
    """Reject one invalid crop without terminating the candidate video evaluation."""

    try:
        return align(frame, face.landmarks)
    except (SpikeError, cv2.error, ValueError):
        counters["alignment_rejects"] = counters.get("alignment_rejects", 0) + 1
        return None
