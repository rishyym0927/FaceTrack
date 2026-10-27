"""Ideal-condition synthetic test cases. Research only; never imported by the product.

Composites DigiFace faces into clean 1280x720 scenes and changes ONE factor at a time (face size,
brightness, blur, noise, mask, JPEG, crowd size) plus the six attendance scenarios and a
look-alike stress. Scenes go through the unchanged frozen detector, quality gate, matcher and
corroboration. Results are SYNTHETIC BENCHMARK performance, not classroom accuracy.

    python -m experiments.ml_accuracy.run_ideal --zip Z --manifest M --out DIR
"""

from __future__ import annotations

import argparse
import json
import random
import time
import zipfile
import zlib
from pathlib import Path

import cv2
import numpy as np
from facetrack_ml.config import canonical_hash, load_profile
from facetrack_ml.pipeline import corroborate, match
from facetrack_ml.runtime import Runtime, align, normalize, quality

from .harness import _opaque_id

FRAMES = 12
STEP_MS = 800
ROSTER = 30
TRIALS = 20
IDEAL = dict(size=130, gain=1.0, blur=0.0, noise=0.0, jpeg=95, mask=False)

# (group, label, overrides, people_known, people_unknown)
SWEEPS = (
    [("size", f"face {s}px", dict(size=s)) for s in (50, 65, 80, 100, 130, 180, 240)]
    + [("brightness", f"gain {g}", dict(gain=g)) for g in (1.4, 1.0, 0.7, 0.5, 0.35, 0.25)]
    + [("blur", f"sigma {b}", dict(blur=b)) for b in (0.0, 0.8, 1.5, 2.5)]
    + [("noise", f"sd {n}", dict(noise=n)) for n in (0, 6, 12, 20)]
    + [("jpeg", f"q{q}", dict(jpeg=q)) for q in (95, 60, 30)]
    + [("mask", "lower face covered", dict(mask=True))]
)
CROWD = (1, 3, 6, 10)


def render(people, params, rng, nrng):
    """people: list of (images, is_known, size). Returns frames and ground-truth rectangles."""
    n = len(people)
    cols = min(n, 6)
    rows = -(-n // cols)
    base = np.full((720, 1280, 3), 120, np.uint8)
    spots = []
    for k, (_, _, size) in enumerate(people):
        cx = int((k % cols + 0.5) * 1280 / cols)
        cy = int((k // cols + 0.5) * 720 / rows)
        spots.append((int(np.clip(cx - size // 2, 0, 1280 - size)),
                      int(np.clip(cy - size // 2, 0, 720 - size))))
    frames, truths = [], []
    for t in range(FRAMES):
        frame = base.copy()
        rects = []
        for (queries, is_known, size), (x, y) in zip(people, spots, strict=True):
            patch = cv2.resize(queries[t % 2], (size, size), interpolation=cv2.INTER_CUBIC)
            if params["mask"]:
                patch[int(size * 0.62):, :] = np.array([200, 200, 205], np.uint8)
            frame[y:y + size, x:x + size] = patch
            rects.append((x, y, x + size, y + size, is_known))
        out = frame.astype(np.float32) * params["gain"]
        if params["noise"]:
            out = out + nrng.normal(0, params["noise"], out.shape)
        out = np.clip(out, 0, 255).astype(np.uint8)
        if params["blur"]:
            out = cv2.GaussianBlur(out, (0, 0), params["blur"])
        ok, enc = cv2.imencode(".jpg", out, [cv2.IMWRITE_JPEG_QUALITY, params["jpeg"]])
        frames.append(cv2.imdecode(enc, cv2.IMREAD_COLOR))
        truths.append(rects)
    return frames, truths


def inside(point, rect):
    return rect[0] <= point[0] <= rect[2] and rect[1] <= point[1] <= rect[3]


def evaluate(runtime, profile, roster, frames, truths):
    hits, found, usable, gt_total, detections, rejects = [], 0, 0, 0, 0, 0
    for t, frame in enumerate(frames):
        faces = runtime.detect(frame, profile.detector_confidence, profile.nms_iou)
        detections += len(faces)
        crops, owners = [], set()
        seen = set()
        for face in faces:
            centre = face.box.reshape(2, 2).mean(axis=0)
            owner = next((i for i, r in enumerate(truths[t]) if inside(centre, r)), None)
            if owner is not None:
                seen.add(owner)
            if not quality(frame, face, profile):
                rejects += 1
                continue
            try:
                crops.append(align(frame, face.landmarks))
            except Exception:
                continue
            if owner is not None:
                owners.add(owner)
        gt_total += len(truths[t])
        found += len(seen)
        usable += len(owners)
        if crops:
            for vector in runtime.embed(crops):
                who, score, margin = match(normalize(vector), roster, profile)
                if who:
                    hits.append({"participant_id": who, "timestamp_ms": t * STEP_MS,
                                 "similarity": score, "margin": margin})
    proposals = {p["participant_id"] for p in corroborate(hits, profile)}
    return proposals, dict(gt=gt_total, found=found, usable=usable, detections=detections,
                           rejects=rejects)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--zip", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--trials", type=int, default=TRIALS)
    parser.add_argument("--models", default=".local/spike/models/buffalo_sc")
    parser.add_argument("--profile", type=Path,
                        default=Path(".local/spike/profiles/frozen-phase1b-v1.json"))
    args = parser.parse_args()

    manifest = json.loads(args.manifest.read_text())
    runtime = Runtime(Path(args.models) / "manifest.json")
    model_hash = canonical_hash(runtime.manifest.model_dump())
    profile = load_profile(args.profile, model_hash)
    seed = manifest["seed"]

    with zipfile.ZipFile(args.zip) as archive:
        lookup = {_opaque_id(p, seed=seed, prefix="asset"): p
                  for p in archive.namelist() if p.lower().endswith(".png")}

        def image(asset):
            data = archive.read(lookup[asset["asset_id"]])
            img = cv2.imdecode(np.frombuffer(data, np.uint8), cv2.IMREAD_COLOR)
            return img if img.shape[:2] == (112, 112) else cv2.resize(img, (112, 112))

        held = [r for r in manifest["identities"] if r["split"] == "held_out"]
        strangers_pool = [r for r in manifest["identities"] if r["split"] == "calibration"]
        templates = {r["identity_id"]: np.stack([runtime.embed([image(a)])[0] for a in r["enrolment"]])
                     for r in held}
        queries = {r["identity_id"]: [image(a) for a in r["queries"]]
                   for r in held + strangers_pool}
    ids = sorted(templates)
    stranger_ids = sorted(r["identity_id"] for r in strangers_pool)

    # Most look-alike pairs: highest cross-identity template similarity (hardest swap risk).
    pairs = []
    for i, a in enumerate(ids):
        for b in ids[i + 1:]:
            pairs.append((float(np.max(normalize(templates[a]) @ normalize(templates[b]).T)), a, b))
    pairs.sort(reverse=True)

    def run_case(group, label, params, n_known, n_unknown, trials, *, fixed=None,
                 size_range=None, empty=False):
        rng = random.Random(f"{group}-{label}")
        nrng = np.random.default_rng(zlib.crc32(f"{group}-{label}".encode()))
        total = dict(trials=0, present=0, found=0, wrong=0, stranger_marked=0, gt=0, face_found=0,
                     usable=0, detections=0, rejects=0, empty_with_marks=0)
        started = time.perf_counter()
        for k in range(trials):
            if fixed:
                present = list(fixed[k % len(fixed)])
            else:
                present = rng.sample(ids, n_known)
            others = rng.sample(ids, ROSTER)
            roster_ids = sorted(set(present) | set(others))
            strangers = rng.sample(stranger_ids, n_unknown)
            people = []
            for who, known in [(p, True) for p in present] + [(s, False) for s in strangers]:
                size = rng.randint(*size_range) if size_range else params["size"]
                people.append((queries[who], known, size))
            if empty:
                frames = [np.full((720, 1280, 3), 120, np.uint8)] * FRAMES
                truths = [[] for _ in range(FRAMES)]
            else:
                frames, truths = render(people, params, rng, nrng)
            proposals, m = evaluate(runtime, profile, {i: templates[i] for i in roster_ids},
                                    frames, truths)
            total["trials"] += 1
            total["present"] += len(present)
            total["found"] += len(set(present) & proposals)
            total["wrong"] += len(proposals - set(present))
            if n_unknown and not present and proposals:
                total["stranger_marked"] += 1
            if not present and not n_unknown and proposals:
                total["empty_with_marks"] += 1
            total["gt"] += m["gt"]
            total["face_found"] += m["found"]
            total["usable"] += m["usable"]
            total["detections"] += m["detections"]
            total["rejects"] += m["rejects"]
        total["group"], total["label"] = group, label
        total["seconds"] = round(time.perf_counter() - started, 1)
        print(f"{group:11s} {label:22s} recall {total['found']}/{total['present']}  "
              f"wrong-present {total['wrong']}  usable {total['usable']}/{total['gt']}", flush=True)
        return total

    results = []
    for group, label, over in SWEEPS:
        results.append(run_case(group, label, {**IDEAL, **over}, 2, 0, args.trials))
    for n in CROWD:
        results.append(run_case("crowd", f"{n} faces in frame", {**IDEAL, "size": 120}, n, 0,
                                args.trials))
    official = [
        ("both known present", 2, 0, {}), ("one enrolled absent", 1, 0, {}),
        ("stranger only", 0, 1, {}), ("known + stranger", 1, 1, {}),
        ("position/size varied", 2, 0, {"size_range": (85, 230)}),
    ]
    for label, nk, nu, extra in official:
        results.append(run_case("scenario", label, IDEAL, nk, nu, args.trials, **extra))
    results.append(run_case("scenario", "no face", IDEAL, 0, 0, args.trials, empty=True))
    lookalikes = [(a, b) for _, a, b in pairs[:args.trials]]
    results.append(run_case("lookalike", "most-similar pairs", IDEAL, 2, 0, len(lookalikes),
                            fixed=lookalikes))

    args.out.mkdir(parents=True, exist_ok=True)
    payload = {"label": "SYNTHETIC BENCHMARK (DigiFace composites, ideal conditions); "
                        "not classroom accuracy",
               "model_hash": model_hash, "profile_hash": canonical_hash(profile.model_dump()),
               "trials_per_case": args.trials, "ideal": IDEAL, "cases": results,
               "max_lookalike_similarity": round(pairs[0][0], 4) if pairs else None}
    (args.out / "ideal_results.json").write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    print("wrote", args.out / "ideal_results.json")


if __name__ == "__main__":
    main()
