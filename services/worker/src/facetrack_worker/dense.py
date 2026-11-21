"""Denser classroom recognition built on the frozen primitives.

The frozen pipeline samples a fixed 12 frames per clip (about 0.8 fps on a 15 s segment),
which leaves a student visible for only a few seconds with too few usable looks. This module
repeats the same steps with the same detector, quality gates, embedding model, thresholds,
margin and corroboration rules, but samples more frames and reports *why* each student was or
was not recognised. Nothing in ``facetrack_ml`` is changed; ``RECOGNITION_SAMPLE_FPS=0``
returns to the frozen path.
"""

from __future__ import annotations

import hashlib
import os
import time
from collections import Counter

import cv2
import numpy as np

from facetrack_ml.config import digest
from facetrack_ml.errors import SpikeError
from facetrack_ml.media import probe, sampled_frames
from facetrack_ml.pipeline import corroborate, match
from facetrack_ml.runtime import align, normalize

DEFAULT_FPS = 4.0
MAX_FRAMES = 100  # hard cap inside the frozen decoder


def sample_fps() -> float:
    try:
        return max(0.0, float(os.environ.get("RECOGNITION_SAMPLE_FPS", DEFAULT_FPS)))
    except ValueError:
        return DEFAULT_FPS


def reject_reason(frame, face, profile) -> str | None:
    """Why the frozen ``quality`` gate would reject a face; None when it passes.

    Mirrors ``facetrack_ml.runtime.quality`` condition for condition so the two stay in step
    (a test asserts it), but names the failing gate.
    """
    h, w = frame.shape[:2]
    x1, y1, x2, y2 = face.box.astype(int)
    if x1 < 0 or y1 < 0 or x2 > w or y2 > h:
        return "edge"
    if min(x2 - x1, y2 - y1) < profile.min_face_pixels:
        return "small"
    if (
        not np.isfinite(face.landmarks).all()
        or np.any(face.landmarks < [x1, y1])
        or np.any(face.landmarks > [x2, y2])
    ):
        return "landmarks"
    gray = cv2.cvtColor(frame[y1:y2, x1:x2], cv2.COLOR_BGR2GRAY)
    if not 5 < gray.mean() < 250:
        return "brightness"
    if cv2.Laplacian(gray, cv2.CV_64F).var() < profile.blur_variance:
        return "blur"
    return None


def _noop(stage, percent=None):
    return None


EMBED_CHUNK = 16


def observe(pipeline, path, fps, frames=sampled_frames, progress=_noop):
    """Detect faces in every sampled frame, then embed the usable ones.

    Two real passes, so progress can be reported honestly: first detection, quality gating and
    alignment (frame by frame), then embedding of the aligned crops in small batches. The crops,
    their order and the model calls are exactly those of the frozen single-pass loop.
    """
    info = probe(path, enrollment=False)
    if info.duration < 1:
        raise SpikeError("CLIP_TOO_SHORT", "A query needs at least 1s.")
    count = min(MAX_FRAMES, max(12, round(info.duration * fps)))
    timings = dict.fromkeys(["decoding_ms", "detection_ms", "embedding_ms", "matching_ms"], 0.0)
    stats = {"sampled_frames": 0, "detections": 0, "quality_rejects": 0, "duplicate_frames": 0}
    rejects, sizes, crops, seen = Counter(), [], [], set()
    runtime, profile = pipeline.runtime, pipeline.profile
    progress("detecting", 0)
    for stamp, frame in frames(path, info, count, timings):
        stats["sampled_frames"] += 1
        key = hashlib.sha256(frame).digest()
        if key in seen:
            stats["duplicate_frames"] += 1
            continue
        seen.add(key)
        started = time.perf_counter()
        faces = runtime.detect(frame, profile.detector_confidence, profile.nms_iou)
        timings["detection_ms"] += (time.perf_counter() - started) * 1000
        stats["detections"] += len(faces)
        for face in faces:
            x1, y1, x2, y2 = face.box.astype(int)
            sizes.append(int(min(x2 - x1, y2 - y1)))
            reason = reject_reason(frame, face, profile)
            if reason is None:
                crops.append((stamp, align(frame, face.landmarks)))
            else:
                stats["quality_rejects"] += 1
                rejects[reason] += 1
        progress("detecting", round(100 * stats["sampled_frames"] / count))
    if not stats["sampled_frames"]:
        raise SpikeError("NO_FRAMES", "Video decoded no frames.")
    observations = []
    progress("recognizing", 0)
    for start in range(0, len(crops), EMBED_CHUNK):
        chunk = crops[start : start + EMBED_CHUNK]
        began = time.perf_counter()
        vectors = runtime.embed([crop for _, crop in chunk])
        timings["embedding_ms"] += (time.perf_counter() - began) * 1000
        observations.extend((stamp, vector) for (stamp, _), vector in zip(chunk, vectors))
        progress("recognizing", round(100 * min(start + EMBED_CHUNK, len(crops)) / len(crops)))
    return observations, timings, stats, info, rejects, sizes


def explain(roster, observations, hits, proposed, profile):
    """One diagnostic row per roster student, in plain terms the teacher app can show."""
    rows = {}
    for person in roster:
        rows[person] = {"seen": 0, "best": None, "ambiguous": 0, "stamps": set()}
    for stamp, vector in observations:
        v = normalize(vector)
        ranked = sorted(
            ((p, float(np.max(t @ v))) for p, t in roster.items()), key=lambda i: (-i[1], i[0])
        )
        (top, score), (_, second) = ranked[:2]
        row = rows[top]
        row["seen"] += 1
        row["best"] = score if row["best"] is None else max(row["best"], score)
        if score >= profile.identity_threshold and score - second < profile.minimum_margin:
            row["ambiguous"] += 1
        row["stamps"].add(stamp)
    out = []
    for person, row in rows.items():
        if person in proposed:
            reason = "recognized"
        elif not row["seen"]:
            reason = "not_seen"
        elif row["ambiguous"]:
            reason = "look_alike"
        elif row["best"] < profile.identity_threshold:
            reason = "weak_match"
        else:
            reason = "seen_too_briefly"
        out.append(
            {
                "student_id": person,
                "reason": reason,
                "observations": row["seen"],
                "best_similarity": None if row["best"] is None else round(row["best"], 4),
            }
        )
    return out


def recognize(pipeline, path, people, store, fps, frames=sampled_frames, progress=_noop):
    start = time.perf_counter()
    roster = store.load(people, pipeline.model_hash, pipeline.profile_hash)
    observations, timings, stats, info, rejects, sizes = observe(
        pipeline, path, fps, frames, progress
    )
    progress("matching", 0)
    profile = pipeline.profile
    hits, unknown = [], 0
    began = time.perf_counter()
    for stamp, vector in observations:
        person, score, margin = match(normalize(vector), roster, profile)
        if person is None:
            unknown += 1
        else:
            hits.append(
                {"participant_id": person, "timestamp_ms": stamp, "similarity": score,
                 "margin": margin}
            )
    proposals = corroborate(hits, profile)
    timings["matching_ms"] = (time.perf_counter() - began) * 1000
    proposed = {item["participant_id"] for item in proposals}
    return {
        "status": "review_required",
        "proposals": proposals,
        "unassessed": sorted(set(people) - proposed),
        "unknown_observations": unknown,
        "quality": stats,
        "diagnostics": explain(roster, observations, hits, proposed, profile),
        "reject_reasons": dict(rejects),
        "face_px_median": int(np.median(sizes)) if sizes else 0,
        "sample_fps": round(stats["sampled_frames"] / info.duration, 2),
        "model_hash": pipeline.model_hash,
        "profile_hash": pipeline.profile_hash,
        "media_sha256": digest(path),
        "duration_seconds": info.duration,
        "timings": pipeline._times(timings, start),
    }
