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
import queue
import threading
import time
from collections import Counter, deque
from concurrent.futures import ThreadPoolExecutor

import cv2
import numpy as np

from facetrack_ml.errors import SpikeError
from facetrack_ml.media import probe, sampled_frames
from facetrack_ml.pipeline import corroborate, match
from facetrack_ml.runtime import align, normalize

from . import media_cache

DEFAULT_FPS = 4.0
MAX_FRAMES = 100  # hard cap inside the frozen decoder


def sample_fps() -> float:
    try:
        return max(0.0, float(os.environ.get("RECOGNITION_SAMPLE_FPS", DEFAULT_FPS)))
    except ValueError:
        return DEFAULT_FPS


MAX_THREADS = 8


def available_cpus() -> int:
    try:
        return max(1, len(os.sched_getaffinity(0)))
    except AttributeError:  # macOS and Windows
        return max(1, os.cpu_count() or 1)


def worker_threads() -> int:
    """Threads that share one job's detection and embedding work.

    ``RECOGNITION_THREADS`` overrides the default of one thread per available core. Two or more
    also give every ONNX session a single thread of its own (``inference.single_thread_sessions``);
    0 or 1 keep the frozen four-thread sessions and the serial loop.
    """
    raw = os.environ.get("RECOGNITION_THREADS")
    try:
        value = available_cpus() if raw is None else int(raw)
    except ValueError:
        value = available_cpus()
    return min(MAX_THREADS, max(0, value))


def pin_sessions() -> bool:
    """Give each ONNX session one intra-op thread (``RECOGNITION_PIN_SESSIONS=1``).

    Off by default: with one thread per session the embeddings differ from the frozen four-thread
    ones by up to about 2e-4 per component (measured), because the floating-point sums are split
    differently. That is far below the matching thresholds but it is not bit-identical, so it is
    an explicit opt-in. The frozen sessions are used unchanged unless this is set.
    """
    return os.environ.get("RECOGNITION_PIN_SESSIONS", "0") == "1"


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

# Embedding is ~44 ms per face on 2 vCPUs and is 85 % of the work, so a crowded segment (18 faces
# in each of 80 frames = 1440 embeddings) took longer than it lasted. Above this many faces in a
# clip only every k-th sampled *frame* is embedded: a student seen for 3 s is still looked at
# about twice a second, far above the two corroborating hits the frozen rules need.
EMBED_BUDGET_DEFAULT = 500


def embed_budget() -> int:
    try:
        return max(0, int(os.environ.get("RECOGNITION_EMBED_BUDGET", EMBED_BUDGET_DEFAULT)))
    except ValueError:
        return EMBED_BUDGET_DEFAULT


def thin(crops, budget):
    """Keep whole frames, evenly spread, so that at most about ``budget`` crops remain.

    Returns (kept crops, k) where k is the frame stride (1 = nothing dropped).
    """
    if budget <= 0 or len(crops) <= budget:
        return crops, 1
    stamps = sorted({stamp for stamp, _ in crops})
    k = -(-len(crops) // budget)
    keep = set(stamps[::k])
    return [c for c in crops if c[0] in keep], k


def prefetched(source, depth=2):
    """Iterate ``source`` in a helper thread so ffmpeg decodes ahead of detection.

    The frozen decoder blocks on its output pipe while a frame is being detected, so decoding
    and detection used to run one after the other. Order is kept, errors reach the consumer
    where they would have occurred, and the helper is stopped and joined on every exit.
    """
    frames, stop, end = queue.Queue(maxsize=depth), threading.Event(), object()

    def put(entry):
        while not stop.is_set():
            try:
                frames.put(entry, timeout=0.1)
                return True
            except queue.Full:
                pass
        return False

    def produce():
        try:
            for item in source:
                if not put((item, None)):
                    return
            put((end, None))
        except BaseException as error:  # handed to the consumer, which re-raises it
            put((None, error))
        finally:
            close = getattr(source, "close", None)
            if close:
                close()

    thread = threading.Thread(target=produce, daemon=True, name="frame-reader")
    thread.start()
    try:
        while True:
            item, error = frames.get()
            if error is not None:
                raise error
            if item is end:
                return
            yield item
    finally:
        stop.set()
        thread.join(timeout=10)


def observe(pipeline, path, fps, frames=sampled_frames, progress=_noop, threads=1):
    """Detect faces in every sampled frame, then embed the usable ones.

    Two real passes, so progress can be reported honestly: first detection, quality gating and
    alignment (frame by frame), then embedding of the aligned crops in small batches. The crops,
    their order and the model calls are exactly those of the frozen single-pass loop. With
    ``threads`` >= 2 several frames (and several chunks of crops) are in flight at once and the
    decoder runs ahead in its own thread; results are merged in frame order, so the observations
    are the same as the serial loop's. ``progress`` is only ever called from the calling thread.
    """
    info = media_cache.once(("probe", False), path, lambda: probe(path, enrollment=False))
    if info.duration < 1:
        raise SpikeError("CLIP_TOO_SHORT", "A query needs at least 1s.")
    count = min(MAX_FRAMES, max(12, round(info.duration * fps)))
    timings = dict.fromkeys(["decoding_ms", "detection_ms", "embedding_ms", "matching_ms"], 0.0)
    stats = {"sampled_frames": 0, "detections": 0, "quality_rejects": 0, "duplicate_frames": 0}
    rejects, sizes, crops, seen = Counter(), [], [], set()
    runtime, profile = pipeline.runtime, pipeline.profile
    parallel = threads >= 2
    pool = ThreadPoolExecutor(threads, thread_name_prefix="recognize") if parallel else None
    done = 0

    def look(frame):
        began = time.perf_counter()
        faces = runtime.detect(frame, profile.detector_confidence, profile.nms_iou)
        spent = (time.perf_counter() - began) * 1000
        found = []
        for face in faces:
            x1, y1, x2, y2 = face.box.astype(int)
            reason = reject_reason(frame, face, profile)
            crop = align(frame, face.landmarks) if reason is None else None
            found.append((int(min(x2 - x1, y2 - y1)), reason, crop))
        return spent, found

    def take(stamp, result):
        nonlocal done
        spent, found = result
        timings["detection_ms"] += spent
        stats["detections"] += len(found)
        for size, reason, crop in found:
            sizes.append(size)
            if reason is None:
                crops.append((stamp, crop))
            else:
                stats["quality_rejects"] += 1
                rejects[reason] += 1
        done += 1
        progress("detecting", round(100 * done / count))

    progress("detecting", 0)
    source = frames(path, info, count, timings)
    if parallel:
        source = prefetched(source)
    pending = deque()
    try:
        for stamp, frame in source:
            stats["sampled_frames"] += 1
            key = hashlib.sha256(frame).digest()
            if key in seen:
                stats["duplicate_frames"] += 1
                done += 1
                continue
            seen.add(key)
            if pool is None:
                take(stamp, look(frame))
                continue
            pending.append((stamp, pool.submit(look, frame)))
            if len(pending) > threads:
                oldest, future = pending.popleft()
                take(oldest, future.result())
        while pending:
            oldest, future = pending.popleft()
            take(oldest, future.result())
        if not stats["sampled_frames"]:
            raise SpikeError("NO_FRAMES", "Video decoded no frames.")
        crops, every = thin(crops, embed_budget())
        timings["embed_every"] = float(every)
        timings["embedded_faces"] = float(len(crops))
        observations = []
        progress("recognizing", 0)
        step = 4 if parallel else EMBED_CHUNK  # small enough for every thread to get work

        def embed(chunk):
            began = time.perf_counter()
            vectors = runtime.embed([crop for _, crop in chunk])
            return chunk, vectors, (time.perf_counter() - began) * 1000

        chunks = [crops[start : start + step] for start in range(0, len(crops), step)]
        embedded = 0
        for chunk, vectors, spent in pool.map(embed, chunks) if pool else map(embed, chunks):
            timings["embedding_ms"] += spent
            observations.extend((stamp, vector) for (stamp, _), vector in zip(chunk, vectors))
            embedded += len(chunk)
            progress("recognizing", round(100 * embedded / len(crops)))
    finally:
        close = getattr(source, "close", None)
        if close:
            close()
        if pool:
            pool.shutdown(wait=True, cancel_futures=True)
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


def embedding_timings(timings):
    """Embedding cost and thinning, kept in the reported timings whatever the pipeline's formatter does.

    The API accepts at most 10 timing keys; with the frozen formatter's two extras this adds none.
    """
    return {
        key: round(timings[key], 3)
        for key in ("embedding_ms", "embed_every", "embedded_faces")
        if key in timings
    }


def recognize(pipeline, path, people, store, fps, frames=sampled_frames, progress=_noop, threads=1):
    start = time.perf_counter()
    roster = store.load(people, pipeline.model_hash, pipeline.profile_hash)
    observations, timings, stats, info, rejects, sizes = observe(
        pipeline, path, fps, frames, progress, threads
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
        "media_sha256": media_cache.sha256(path),
        "duration_seconds": info.duration,
        "timings": {**pipeline._times(timings, start), **embedding_timings(timings)},
    }
