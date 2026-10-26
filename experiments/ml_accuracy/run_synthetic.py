"""Synthetic DigiFace attendance simulation. Research only; never imported by the product.

Frames are composited from licensed DigiFace images on a plain background with deterministic
degradations, then pushed through the *unchanged* frozen detector/recognizer/matcher and
corroboration code. Results are SYNTHETIC BENCHMARK performance, not classroom accuracy.

    python -m experiments.ml_accuracy.run_synthetic prepare --zip Z --out DIR
    python -m experiments.ml_accuracy.run_synthetic run --zip Z --manifest M --variant V --run 1 --out DIR
"""

from __future__ import annotations

import argparse
import hashlib
import json
import random
import time
import zipfile
from collections import defaultdict
from pathlib import Path

import cv2
import numpy as np
from facetrack_ml.config import canonical_hash, load_profile
from facetrack_ml.pipeline import corroborate, match
from facetrack_ml.runtime import Runtime, normalize, quality

from .harness import (
    AttendanceOutcome,
    _opaque_id,
    attendance_metrics,
    build_digiface_manifest,
    write_aggregate_results,
    write_frozen_manifest,
)
from .pipeline import (
    CandidateConfig,
    CandidateQualityGate,
    DetectorFrame,
    MultiScaleScrfd,
    safe_align,
)

VARIANTS = ("baseline", "clahe_detector_only", "contrast_filter", "two_scale")
FRAMES = 12
STEP_MS = 800
ROSTER = 30
LEVELS = {
    "easy": dict(gain=(0.8, 1.1), blur=0.0, jpeg=90, noise=3, occ=0.0, glare=0.0),
    "medium": dict(gain=(0.5, 0.75), blur=1.2, jpeg=60, noise=6, occ=0.15, glare=0.2),
    "hard": dict(gain=(0.3, 0.5), blur=2.2, jpeg=35, noise=10, occ=0.35, glare=0.4),
}


def level_of(scene_id: str) -> str:
    n = int(scene_id.rsplit("-", 1)[1])
    return "easy" if n < 4 else "medium" if n < 7 else "hard"


def build_index(archive: zipfile.ZipFile) -> dict[str, list[str]]:
    index: dict[str, list[str]] = defaultdict(list)
    for name in archive.namelist():
        if name.lower().endswith(".png"):
            index[name.rsplit("/", 1)[0]].append(name)
    return {k: sorted(v) for k, v in index.items()}


def prepare(args) -> None:
    with zipfile.ZipFile(args.zip) as archive:
        index = build_index(archive)
        manifest = build_digiface_manifest(index, seed=args.seed)
        for record in manifest["identities"]:
            for asset in record["enrolment"] + record["queries"]:
                asset["sha256"] = "set-at-run"
        # Fill real source hashes from the archive so the frozen manifest pins the exact inputs.
        lookup = {
            _opaque_id(path, seed=args.seed, prefix="asset"): path
            for files in index.values()
            for path in files
        }
        for record in manifest["identities"]:
            for asset in record["enrolment"] + record["queries"]:
                asset["sha256"] = hashlib.sha256(archive.read(lookup[asset["asset_id"]])).hexdigest()
    digest = write_frozen_manifest(manifest, args.out / "manifest.json")
    print(json.dumps({"manifest_sha256": digest, "identities": len(manifest["identities"]),
                      "scenes": len(manifest["scenes"])}))


def degrade_patch(patch: np.ndarray, level: dict, rng: random.Random) -> np.ndarray:
    patch = patch.copy()
    h, w = patch.shape[:2]
    if rng.random() < level["occ"]:  # lower-face occlusion (mask-like)
        patch[int(h * 0.62):, :] = np.array([200, 200, 205], np.uint8)
    if rng.random() < level["glare"]:  # specular glare over one eye region
        overlay = patch.copy()
        cv2.ellipse(overlay, (int(w * 0.3), int(h * 0.38)), (int(w * 0.18), int(h * 0.1)),
                    0, 0, 360, (255, 255, 255), -1)
        patch = cv2.addWeighted(overlay, 0.75, patch, 0.25, 0)
    return patch


def make_frames(scene: dict, known: list[np.ndarray], unknown: list[np.ndarray]):
    """known/unknown are lists of two 112x112 query images. Returns frames and gt rectangles."""
    rng = random.Random(scene["seed"])
    nrng = np.random.default_rng(scene["seed"])
    level = LEVELS[level_of(scene["scene_id"])]
    people = [(q, True) for q in known] + [(q, False) for q in unknown]
    wide = scene["scenario"] == "position_scale"
    spec = []
    for k, (queries, is_known) in enumerate(people):
        size = rng.randint(85, 230) if wide else rng.randint(110, 150)
        x = rng.randint(40, 1280 - size - 40) if wide else 150 + k * 420 + rng.randint(-40, 40)
        y = rng.randint(40, 720 - size - 40) if wide else 190 + rng.randint(-30, 30)
        spec.append((queries, is_known, size, x, y))
    if wide and len(spec) == 2:  # keep the two faces from overlapping
        a, b = spec[0], spec[1]
        if abs(a[3] - b[3]) < max(a[2], b[2]) and abs(a[4] - b[4]) < max(a[2], b[2]):
            spec[1] = (b[0], b[1], b[2], (a[3] + 500) % (1280 - b[2] - 40) + 20, b[4])
    base = np.full((720, 1280, 3), rng.randint(90, 140), np.uint8)
    gradient = np.linspace(-18, 18, 1280, dtype=np.float32)[None, :, None]
    base = np.clip(base.astype(np.float32) + gradient, 0, 255).astype(np.uint8)
    for _ in range(4):
        x1, y1 = rng.randint(0, 1000), rng.randint(380, 640)
        cv2.rectangle(base, (x1, y1), (x1 + rng.randint(120, 260), y1 + rng.randint(40, 90)),
                      (rng.randint(60, 110),) * 3, -1)
    gain = rng.uniform(*level["gain"])
    frames, truths = [], []
    for t in range(FRAMES):
        frame = base.copy()
        rects = []
        for queries, is_known, size, x, y in spec:
            s = max(70, int(size * rng.uniform(0.94, 1.06)))
            px = int(np.clip(x + rng.randint(-6, 6), 0, 1280 - s))
            py = int(np.clip(y + rng.randint(-6, 6), 0, 720 - s))
            patch = cv2.resize(queries[t % 2], (s, s), interpolation=cv2.INTER_CUBIC)
            frame[py:py + s, px:px + s] = degrade_patch(patch, level, rng)
            rects.append((px, py, px + s, py + s, is_known))
        out = np.clip(frame.astype(np.float32) * gain + nrng.normal(0, level["noise"], frame.shape), 0, 255)
        out = out.astype(np.uint8)
        if level["blur"]:
            out = cv2.GaussianBlur(out, (0, 0), level["blur"])
        ok, enc = cv2.imencode(".jpg", out, [cv2.IMWRITE_JPEG_QUALITY, level["jpeg"]])
        frames.append(cv2.imdecode(enc, cv2.IMREAD_COLOR))
        truths.append(rects)
    return frames, truths


def inside(point, rect) -> bool:
    return rect[0] <= point[0] <= rect[2] and rect[1] <= point[1] <= rect[3]


def run(args) -> None:
    manifest_json = json.loads(args.manifest.read_text())
    models = Path(args.models)
    runtime = Runtime(models / "manifest.json")
    model_hash = canonical_hash(runtime.manifest.model_dump())
    profile = load_profile(args.profile, model_hash)
    gate = CandidateQualityGate(CandidateConfig(
        blur_variance=profile.blur_variance, min_face_pixels=profile.min_face_pixels,
        contrast_std=25.0 if args.variant == "contrast_filter" else None))
    two_scale = MultiScaleScrfd(runtime.detector, runtime.manifest, (640, 960))
    seed = manifest_json["seed"]

    with zipfile.ZipFile(args.zip) as archive:
        lookup = {_opaque_id(p, seed=seed, prefix="asset"): p
                  for p in archive.namelist() if p.lower().endswith(".png")}

        def image(asset):
            data = archive.read(lookup[asset["asset_id"]])
            img = cv2.imdecode(np.frombuffer(data, np.uint8), cv2.IMREAD_COLOR)
            return img if img.shape[:2] == (112, 112) else cv2.resize(img, (112, 112))

        held_out = [r for r in manifest_json["identities"] if r["split"] == "held_out"]
        unknowns = [r for r in manifest_json["identities"] if r["split"] == "calibration"]
        templates = {r["identity_id"]: np.stack([runtime.embed([image(a)])[0] for a in r["enrolment"]])
                     for r in held_out}
        queries = {r["identity_id"]: [image(a) for a in r["queries"]]
                   for r in held_out + unknowns}

    rows, stats = [], defaultdict(lambda: defaultdict(float))
    scene_digests, timings = {}, []
    ids = sorted(templates)
    for scene in manifest_json["scenes"]:
        rng = random.Random(scene["seed"] + 7)
        scenario, level = scene["scenario"], level_of(scene["scene_id"])
        n_known = {"both_known": 2, "one_absent": 1, "unknown_only": 0, "known_plus_unknown": 1,
                   "position_scale": 2, "no_face": 0}[scenario]
        n_unknown = {"unknown_only": 1, "known_plus_unknown": 1}.get(scenario, 0)
        present = rng.sample(ids, n_known)
        roster_ids = sorted(set(present) | set(rng.sample(ids, ROSTER)))[:max(ROSTER, n_known)]
        roster_ids = sorted(set(roster_ids) | set(present))
        strangers = [r["identity_id"] for r in rng.sample(unknowns, n_unknown)]
        frames, truths = make_frames(scene, [queries[i] for i in present], [queries[i] for i in strangers])
        roster = {i: templates[i] for i in roster_ids}

        started = time.perf_counter()
        hits, detections, rejects, gt_total, gt_found, gt_usable, false_det = [], 0, 0, 0, 0, 0, 0
        for t, frame in enumerate(frames):
            source = frame
            if args.variant == "clahe_detector_only":
                source = DetectorFrame.prepare(frame, clahe=True).detector
            faces = (two_scale.detect(frame, profile.detector_confidence, profile.nms_iou)
                     if args.variant == "two_scale"
                     else runtime.detect(source, profile.detector_confidence, profile.nms_iou))
            detections += len(faces)
            crops, owners = [], []
            for face in faces:
                centre = face.box.reshape(2, 2).mean(axis=0)
                owner = next((r for r in truths[t] if inside(centre, r)), None)
                if owner is None:
                    false_det += 1
                passed = (gate.reject_reason(frame, face) is None if args.variant == "contrast_filter"
                          else quality(frame, face, profile))
                if not passed:
                    rejects += 1
                    continue
                crop = safe_align(frame, face, stats["align"])
                if crop is not None:
                    crops.append(crop)
                    owners.append(owner)
            gt_total += len(truths[t])
            found = {id(o) for o in
                     (next((r for r in truths[t] if inside(f.box.reshape(2, 2).mean(axis=0), r)), None)
                      for f in faces) if o is not None}
            gt_found += len(found)
            gt_usable += len({id(o) for o in owners if o is not None})
            if crops:
                for vector in runtime.embed(crops):
                    who, score, margin = match(normalize(vector), roster, profile)
                    if who is not None:
                        hits.append({"participant_id": who, "timestamp_ms": t * STEP_MS,
                                     "similarity": score, "margin": margin})
        timings.append((time.perf_counter() - started) * 1000)
        proposals = {p["participant_id"] for p in corroborate(hits, profile)}
        usable = detections - rejects
        sufficient = FRAMES >= 2 and usable >= 2  # same rule as services/api recognition_jobs.py
        for person in roster_ids:
            rows.append(AttendanceOutcome(
                f"{scene['scene_id']}", scenario, person, person in present, person in proposals,
                True, sufficient))
        s = stats[level]
        s["scenes"] += 1
        s["gt_faces"] += gt_total
        s["gt_detected"] += gt_found
        s["gt_usable"] += gt_usable
        s["false_detections"] += false_det
        s["present_students"] += len(present)
        s["present_proposed"] += len(set(present) & proposals)
        s["present_would_be_not_recognized"] += len(set(present) - proposals) if sufficient else 0
        s["absent_wrongly_present"] += len(proposals - set(present))
        if n_unknown and not present:
            s["unknown_only_scenes"] += 1
            s["unknown_only_scenes_with_false_presence"] += 1 if proposals else 0
        scene_digests[scene["scene_id"]] = sorted(proposals)

    out = args.out / args.variant / f"run{args.run}"
    write_aggregate_results(rows, out)
    by_level = {lv: attendance_metrics([r for r in rows if level_of(r.video_id) == lv]) for lv in LEVELS}
    extra = {
        "label": "SYNTHETIC BENCHMARK (DigiFace composites); not classroom accuracy",
        "variant": args.variant, "run": args.run, "manifest_sha256": hashlib.sha256(
            args.manifest.read_bytes()).hexdigest(),
        "model_hash": model_hash, "profile_hash": canonical_hash(profile.model_dump()),
        "by_level": by_level,
        "detection_by_level": {lv: dict(v) for lv, v in stats.items() if lv in LEVELS},
        "alignment_rejects": stats["align"].get("alignment_rejects", 0),
        "scene_time_ms": {"median": float(np.median(timings)),
                          "p95": float(np.percentile(timings, 95)), "frames_per_scene": FRAMES},
        "decision_digest": hashlib.sha256(json.dumps(scene_digests, sort_keys=True).encode()).hexdigest(),
    }
    (out / "extra.json").write_text(json.dumps(extra, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"variant": args.variant, "run": args.run, "digest": extra["decision_digest"][:12],
                      "p95_ms": round(extra["scene_time_ms"]["p95"], 1)}))


def main() -> None:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("prepare")
    p.add_argument("--zip", type=Path, required=True)
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--seed", type=int, default=26028)
    r = sub.add_parser("run")
    r.add_argument("--zip", type=Path, required=True)
    r.add_argument("--manifest", type=Path, required=True)
    r.add_argument("--variant", choices=VARIANTS, required=True)
    r.add_argument("--run", type=int, default=1)
    r.add_argument("--out", type=Path, required=True)
    r.add_argument("--models", default=".local/spike/models/buffalo_sc")
    r.add_argument("--profile", type=Path, default=Path(".local/spike/profiles/frozen-phase1b-v1.json"))
    args = parser.parse_args()
    prepare(args) if args.command == "prepare" else run(args)


if __name__ == "__main__":
    main()
