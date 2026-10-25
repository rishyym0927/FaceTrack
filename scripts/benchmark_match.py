#!/usr/bin/env python3
"""Synthetic NumPy roster-match microbenchmark; excludes video and worker costs."""

from __future__ import annotations

import json
import statistics
import time

import numpy as np
from facetrack_ml.config import Profile
from facetrack_ml.pipeline import match
from facetrack_ml.runtime import normalize


def bench(students: int, repeats: int = 100) -> dict:
    random = np.random.default_rng(42)
    roster = {f"synthetic-{n}": normalize(random.standard_normal((5, 512)))
              for n in range(students)}
    queries = normalize(random.standard_normal((12, 512)))
    profile = Profile(model_hash="0" * 64, calibration_id="synthetic-matcher-only",
                      identity_threshold=0.8, minimum_margin=0.1,
                      enrollment_consistency=0.7)
    elapsed = []
    for _ in range(repeats):
        start = time.perf_counter()
        for query in queries:
            match(query, roster, profile)
        elapsed.append((time.perf_counter() - start) * 1000)
    values = sorted(elapsed)
    return {"students": students, "templates_per_student": 5, "queries_per_clip": 12,
            "repeats": repeats, "median_match_ms": round(statistics.median(values), 3),
            "p95_match_ms": round(values[int(0.95 * (len(values) - 1))], 3)}


if __name__ == "__main__":
    print(json.dumps({"scope": "synthetic_matcher_only_no_video_or_queue",
                      "results": [bench(n) for n in (30, 60, 120)]}, indent=2))
