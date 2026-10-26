"""Realistic synthetic CLASSROOM simulation. Research only; never imported by the product.

Goes beyond run_synthetic.py by composing many DigiFace identities into a classroom:
rows at varying depth (front = large faces, back = small), a side-window lighting
gradient, natural per-frame appearance from each identity's many renders, absent
roster members (to measure false presence) and unknown intruders (to measure
unknown->roster leakage). It pushes every frame through the *unchanged* frozen
detector/recognizer/matcher/corroboration, and reports recall, false presence and
IDENTITY CONFUSION broken down by face-size bucket (seat depth) and lighting.

Results are a SYNTHETIC BENCHMARK, not classroom accuracy: DigiFace renders are
112x112 so even "front-row" faces carry no more than 112px of real detail, which
makes this test conservative. It does not replace 2-3 real participants.

    python -m experiments.ml_accuracy.run_classroom --zip Z --out DIR [--rooms 8] [--run 1]
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

from .pipeline import safe_align

W, H, FRAMES, STEP_MS = 1920, 1080, 10, 800
ENROL_IMGS = (0, 1, 2)          # disjoint from query frames
QUERY_POOL = list(range(12, 72))  # natural variation, never the enrolment images


def size_bucket(px: int) -> str:
    return "front(>=140px)" if px >= 140 else "middle(90-139)" if px >= 90 else "back(<90)"


def load_index(archive: zipfile.ZipFile) -> dict[str, list[str]]:
    index: dict[str, list[str]] = defaultdict(list)
    for name in archive.namelist():
        if name.lower().endswith(".png"):
            index[name.split("/", 1)[0]].append(name)
    return {k: v for k, v in index.items() if len(v) >= 72}


def read_img(archive, name):
    img = cv2.imdecode(np.frombuffer(archive.read(name), np.uint8), cv2.IMREAD_COLOR)
    return img


def classroom_background(rng):
    base = np.full((H, W, 3), 150, np.uint8).astype(np.float32)
    # wall vertical shading
    base += np.linspace(25, -25, H, dtype=np.float32)[:, None, None]
    # rows of desks in the lower third
    for ry in range(int(H * 0.55), H, 110):
        cv2.rectangle(base, (0, ry), (W, ry + 70), (95, 90, 85), -1)
    return np.clip(base, 0, 255).astype(np.uint8)


def seat_layout(rng, n_rows, n_cols):
    """Return seats as (row, col, cx, cy, face_px). Front rows larger + lower in frame."""
    seats = []
    for r in range(n_rows):
        depth = r / max(1, n_rows - 1)                 # 0 front .. 1 back
        face_px = int(round(190 - depth * 130))        # 190 front -> 60 back
        cy = int(H * (0.30 + depth * 0.42))
        span = int(W * (0.86 - depth * 0.18))
        x0 = (W - span) // 2
        for c in range(n_cols):
            cx = x0 + int(span * (c + 0.5) / n_cols) + rng.randint(-12, 12)
            seats.append((r, c, cx, cy + rng.randint(-10, 10), face_px))
    return seats


def paste_face(frame, face, cx, cy, px, light, rng):
    f = cv2.resize(face, (px, px), interpolation=cv2.INTER_AREA if px < face.shape[0] else cv2.INTER_CUBIC)
    f = np.clip(f.astype(np.float32) * light, 0, 255).astype(np.uint8)
    x, y = int(cx - px / 2), int(cy - px / 2)
    x = max(0, min(W - px, x))
    y = max(0, min(H - px, y))
    frame[y:y + px, x:x + px] = f
    return (x, y, x + px, y + px)


def run(args):
    rng = random.Random(args.run * 1000 + 7)
    n_frames = args.frames
    models = Path(args.models)
    runtime = Runtime(models / "manifest.json")
    model_hash = canonical_hash(runtime.manifest.model_dump())
    profile = load_profile(args.profile, model_hash)

    with zipfile.ZipFile(args.zip) as archive:
        index = load_index(archive)
        all_ids = sorted(index)
        rng.shuffle(all_ids)

        def img112(name):
            im = read_img(archive, name)
            return im if im.shape[:2] == (112, 112) else cv2.resize(im, (112, 112))

        rooms = []
        cursor = 0
        for room_i in range(args.rooms):
            n_rows, n_cols = rng.choice([(4, 4), (4, 5), (5, 4)])
            seats = seat_layout(rng, n_rows, n_cols)
            # fill ~85% of seats; the rest empty
            filled = [s for s in seats if rng.random() < 0.85]
            need = len(filled)
            ids = all_ids[cursor:cursor + need + 8]
            cursor += need
            seated = ids[:need]
            present = set(seated[:need - max(1, need // 8)])  # a couple are "unknown intruders"
            intruders = set(seated) - present                 # seated but NOT on roster
            absent = set(ids[need:need + 7])                   # on roster, not in the room
            roster_ids = sorted(present | absent)
            rooms.append(dict(room=room_i, seats=filled, seated=seated,
                              present=present, intruders=intruders, roster=roster_ids,
                              light_dir=rng.choice([-1, 1])))

        # enrolment templates (frozen) for every roster/present id we will need
        need_templates = set()
        for rm in rooms:
            need_templates |= set(rm["roster"]) | rm["present"]
        templates = {}
        for pid in need_templates:
            crops = [img112(f"{pid}/{i}.png") for i in ENROL_IMGS]
            templates[pid] = np.stack([runtime.embed([c])[0] for c in crops])

        # per-seat identity frame images (natural variation)
        def frame_face(pid, t):
            name = f"{pid}/{QUERY_POOL[(hash((pid, t)) % len(QUERY_POOL))]}.png"
            return read_img(archive, name)

        buckets = ["front(>=140px)", "middle(90-139)", "back(<90)"]
        agg = {
            "present": 0, "recalled": 0, "false_presence": 0, "unknown_leak": 0,
            "identity_confusions": 0, "crops_matched": 0,
            "by_bucket": {b: {"present": 0, "recalled": 0} for b in buckets},
            "by_light": {"lit": {"present": 0, "recalled": 0}, "dim": {"present": 0, "recalled": 0}},
            "detect_gt": 0, "detect_found": 0, "quality_rejects": 0, "detections": 0,
        }
        timings = []
        digest_src = {}

        for rm in rooms:
            # assign each seat an identity
            seat_ids = {}
            for seat, pid in zip(rm["seats"], rm["seated"]):
                seat_ids[seat] = pid
            background = classroom_background(random.Random(rm["room"]))
            # horizontal lighting gradient (window on one side)
            grad = np.linspace(1.18, 0.72, W, dtype=np.float32)[::rm["light_dir"]]
            seat_light = {s: float(grad[max(0, min(W - 1, s[2]))]) for s in rm["seats"]}

            frames, gt_rects = [], []
            for t in range(n_frames):
                frame = background.copy()
                rects = []
                for seat in rm["seats"]:
                    pid = seat_ids[seat]
                    r, c, cx, cy, px = seat
                    jpx = max(48, int(px * random.Random(hash((rm["room"], seat, t)) & 0xffff).uniform(0.96, 1.04)))
                    face = frame_face(pid, t)
                    # occasional head-turn/look-away: skip the face on some frames
                    if random.Random(hash((pid, t, "look")) & 0xffff).random() < 0.12:
                        continue
                    box = paste_face(frame, face, cx, cy, jpx, seat_light[seat], random)
                    rects.append((box, pid, seat, jpx))
                # mild classroom-camera degradation
                frame = cv2.GaussianBlur(frame, (0, 0), 0.6)
                noise = np.random.default_rng(hash((rm["room"], t)) & 0xffff).normal(0, 3, frame.shape)
                frame = np.clip(frame.astype(np.float32) + noise, 0, 255).astype(np.uint8)
                ok, enc = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, 70])
                frames.append(cv2.imdecode(enc, cv2.IMREAD_COLOR))
                gt_rects.append(rects)

            roster = {i: templates[i] for i in rm["roster"]}
            started = time.perf_counter()
            hits = []
            for t, frame in enumerate(frames):
                faces = runtime.detect(frame, profile.detector_confidence, profile.nms_iou)
                agg["detections"] += len(faces)
                agg["detect_gt"] += len(gt_rects[t])
                # match detections to ground-truth seats by centre
                for face in faces:
                    cx, cy = face.box.reshape(2, 2).mean(axis=0)
                    owner = None
                    for (bx1, by1, bx2, by2), pid, seat, jpx in gt_rects[t]:
                        if bx1 <= cx <= bx2 and by1 <= cy <= by2:
                            owner = (pid, seat, jpx)
                            break
                    if owner is not None:
                        agg["detect_found"] += 1
                    if not quality(frame, face, profile):
                        agg["quality_rejects"] += 1
                        continue
                    crop = safe_align(frame, face, defaultdict(float))
                    if crop is None:
                        continue
                    vec = normalize(runtime.embed([crop])[0])
                    who, score, margin = match(vec, roster, profile)
                    if who is not None:
                        agg["crops_matched"] += 1
                        hits.append({"participant_id": who, "timestamp_ms": t * STEP_MS,
                                     "similarity": score, "margin": margin})
                        if owner is not None and who != owner[0] and who in roster:
                            agg["identity_confusions"] += 1
            timings.append((time.perf_counter() - started) * 1000 / max(1, n_frames))
            proposals = {p["participant_id"] for p in corroborate(hits, profile)}
            digest_src[str(rm["room"])] = sorted(proposals)

            present = rm["present"]
            agg["present"] += len(present)
            agg["recalled"] += len(present & proposals)
            agg["false_presence"] += len(proposals - set(rm["seated"]))  # absent roster proposed
            agg["unknown_leak"] += len(proposals & rm["intruders"])       # intruder proposed as roster
            # per-seat bucket/light recall (present students only)
            seat_of = {pid: seat for seat, pid in seat_ids.items()}
            for pid in present:
                seat = seat_of[pid]
                b = size_bucket(seat[4])
                agg["by_bucket"][b]["present"] += 1
                lit = "lit" if seat_light[seat] >= 0.95 else "dim"
                agg["by_light"][lit]["present"] += 1
                if pid in proposals:
                    agg["by_bucket"][b]["recalled"] += 1
                    agg["by_light"][lit]["recalled"] += 1

        agg["detect_rate"] = round(agg["detect_found"] / max(1, agg["detect_gt"]), 3)
        agg["recall"] = round(agg["recalled"] / max(1, agg["present"]), 3)
        agg["frame_ms_median"] = round(float(np.median(timings)), 1)
        agg["frame_ms_p95"] = round(float(np.percentile(timings, 95)), 1)
        agg["rooms"] = args.rooms
        agg["frames"] = n_frames
        agg["run"] = args.run
        agg["model_hash"] = model_hash
        agg["profile_hash"] = canonical_hash(profile.model_dump())
        agg["decision_digest"] = hashlib.sha256(
            json.dumps(digest_src, sort_keys=True).encode()).hexdigest()
        agg["label"] = "SYNTHETIC CLASSROOM BENCHMARK (DigiFace); not real classroom accuracy"

    out = args.out / f"classroom-run{args.run}.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(agg, indent=2, sort_keys=True) + "\n")
    # readable one-line-per-metric summary
    print(json.dumps({k: agg[k] for k in (
        "rooms", "present", "recall", "false_presence", "unknown_leak",
        "identity_confusions", "detect_rate", "quality_rejects", "detections",
        "frame_ms_median", "frame_ms_p95", "decision_digest")}, indent=2))
    for b in ("front(>=140px)", "middle(90-139)", "back(<90)"):
        d = agg["by_bucket"][b]
        print(f"  {b}: recall {d['recalled']}/{d['present']}")
    for lit in ("lit", "dim"):
        d = agg["by_light"][lit]
        print(f"  {lit}: recall {d['recalled']}/{d['present']}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--zip", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--rooms", type=int, default=8)
    ap.add_argument("--run", type=int, default=1)
    ap.add_argument("--frames", type=int, default=FRAMES,
                    help="frames sampled per room; more = longer video of the same framing")
    ap.add_argument("--models", default=".local/spike/models/buffalo_sc")
    ap.add_argument("--profile", type=Path, default=Path(".local/spike/profiles/frozen-phase1b-v1.json"))
    run(ap.parse_args())


if __name__ == "__main__":
    main()
