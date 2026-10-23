from __future__ import annotations

import hashlib
import time
from collections import defaultdict
from pathlib import Path

import numpy as np

from .config import Profile, canonical_hash, digest
from .errors import SpikeError
from .media import probe, sampled_frames
from .runtime import Runtime, align, normalize, quality
from .store import TemplateStore


def match(vector: np.ndarray, roster: dict[str, np.ndarray], profile: Profile):
    if len(roster) < 2:
        raise SpikeError("INVALID_ROSTER", "At least two identities are required for margin matching.")
    scores = sorted(((person, float(np.max(templates @ vector)))
                     for person, templates in roster.items()), key=lambda item: (-item[1], item[0]))
    (person, score), (_, second) = scores[:2]
    margin = score - second
    if score >= profile.identity_threshold and margin >= profile.minimum_margin:
        return person, score, margin
    return None, score, margin


def corroborate(hits: list[dict], profile: Profile) -> list[dict]:
    groups = defaultdict(list)
    for hit in hits:
        groups[hit["participant_id"]].append(hit)
    result = []
    for person, observations in sorted(groups.items()):
        # Multiple visible faces mapping to one person in the same frame are a conflict.
        stamps = [o["timestamp_ms"] for o in observations]
        if len(stamps) != len(set(stamps)):
            continue
        distinct = sorted(set(stamps))
        if len(distinct) >= profile.min_hits and distinct[-1] - distinct[0] >= profile.min_span_ms:
            result.append({"participant_id": person, "decision": "proposed_present",
                           "hits": len(distinct), "span_ms": distinct[-1] - distinct[0],
                           "median_similarity": round(float(np.median(
                               [o["similarity"] for o in observations])), 6)})
    return result


class Pipeline:
    def __init__(self, runtime: Runtime, profile: Profile, model_hash: str):
        self.runtime, self.profile, self.model_hash = runtime, profile, model_hash
        self.profile_hash = canonical_hash(profile.model_dump())

    def observe(self, path: Path, *, enrollment: bool):
        info = probe(path, enrollment=enrollment)
        if info.duration < (10 if enrollment else 1):
            raise SpikeError("CLIP_TOO_SHORT", "Enrolment needs 10s; a query needs at least 1s.")
        timings = dict.fromkeys(["decoding_ms", "detection_ms", "embedding_ms", "matching_ms"], 0.0)
        observations = []
        stats = {"sampled_frames": 0, "detections": 0, "quality_rejects": 0,
                 "duplicate_frames": 0}
        seen_frames = set()
        count = min(60, int(info.duration * 3)) if enrollment else 12
        for stamp, frame in sampled_frames(path, info, count, timings):
            stats["sampled_frames"] += 1
            frame_hash = hashlib.sha256(frame).digest()
            if frame_hash in seen_frames:
                stats["duplicate_frames"] += 1
                continue
            seen_frames.add(frame_hash)
            started = time.perf_counter()
            faces = self.runtime.detect(frame, self.profile.detector_confidence, self.profile.nms_iou)
            timings["detection_ms"] += (time.perf_counter() - started) * 1000
            stats["detections"] += len(faces)
            if enrollment and len(faces) > 1:
                raise SpikeError("MULTIPLE_FACES", "Re-record enrolment with only one face visible.")
            crops = []
            for face in faces:
                if quality(frame, face, self.profile):
                    crops.append(align(frame, face.landmarks))
                else:
                    stats["quality_rejects"] += 1
            if crops:
                started = time.perf_counter()
                # Per-frame bounded grouping; Runtime supports batch-one model artifacts.
                vectors = self.runtime.embed(crops)
                timings["embedding_ms"] += (time.perf_counter() - started) * 1000
                observations.extend((stamp, vector) for vector in vectors)
        if not stats["sampled_frames"]:
            raise SpikeError("NO_FRAMES", "Video decoded no frames.")
        return observations, timings, stats, info

    def enrol(self, path: Path, person: str, store: TemplateStore) -> dict:
        start = time.perf_counter()
        observations, timings, stats, info = self.observe(path, enrollment=True)
        if len(observations) < 3 or observations[-1][0] - observations[0][0] < 500:
            raise SpikeError("ENROLLMENT_QUALITY", "Not enough separated usable facial observations.")
        vectors = np.stack([v for _, v in observations])
        # Check every retained candidate against a representative observation, not only the mean.
        pairwise = vectors @ vectors.T
        medoid = int(np.argmax(np.median(pairwise, axis=1)))
        if np.any(pairwise[medoid] < self.profile.enrollment_consistency):
            raise SpikeError("INCONSISTENT_IDENTITY", "Enrolment observations are inconsistent.")
        indexes = np.linspace(0, len(vectors) - 1, min(5, len(vectors)), dtype=int)
        store.save(person, vectors[indexes], self.model_hash, self.profile_hash)
        return {"status": "enrolled_local_supervised", "participant_id": person,
                "template_count": len(indexes), "model_hash": self.model_hash,
                "profile_hash": self.profile_hash, "media_sha256": digest(path),
                "duration_seconds": info.duration, "quality": stats,
                "timings": self._times(timings, start)}

    def recognize(self, path: Path, people: list[str], store: TemplateStore) -> dict:
        start = time.perf_counter()
        roster = store.load(people, self.model_hash, self.profile_hash)
        observations, timings, stats, info = self.observe(path, enrollment=False)
        hits, unknown = [], 0
        matching_start = time.perf_counter()
        for stamp, vector in observations:
            person, score, margin = match(normalize(vector), roster, self.profile)
            if person is None:
                unknown += 1
            else:
                hits.append({"participant_id": person, "timestamp_ms": stamp,
                             "similarity": score, "margin": margin})
        proposals = corroborate(hits, self.profile)
        timings["matching_ms"] = (time.perf_counter() - matching_start) * 1000
        proposed = {item["participant_id"] for item in proposals}
        return {"status": "review_required", "proposals": proposals,
                "unassessed": sorted(set(people) - proposed), "unknown_observations": unknown,
                "quality": stats, "model_hash": self.model_hash, "profile_hash": self.profile_hash,
                "media_sha256": digest(path), "duration_seconds": info.duration,
                "timings": self._times(timings, start),
                "limitations": ["local_poc_only", "not_liveness_verified",
                                "not_classroom_accuracy_validation"]}

    def _times(self, timings: dict, started: float):
        return {**{key: round(value, 3) for key, value in timings.items()},
                "cold_start_ms": round(self.runtime.cold_start_ms, 3),
                "processing_total_ms": round((time.perf_counter() - started) * 1000, 3)}
