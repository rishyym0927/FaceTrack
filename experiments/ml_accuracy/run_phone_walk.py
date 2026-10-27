"""Synthetic 'teacher walks the room with a good phone' simulation. Research only.

Models the recommended capture: instead of one fixed wide shot (tiny back-row
faces), the teacher's phone passes each student CLOSE-UP and sharp. Over the
recording every student is visited and appears as a large, well-lit face in a
few frames -- except a realistic fraction who look down / turn away / are
occluded and stay hard even with a good phone. Absent roster members and a few
unknown intruders are included to measure false presence and leakage.

Everything runs through the UNCHANGED frozen pipeline. SYNTHETIC BENCHMARK, not
real classroom accuracy; DigiFace renders are 112px so this is still a model of
reality, not reality. Final validation needs real participants.

    python -m experiments.ml_accuracy.run_phone_walk --zip Z --out DIR [--present 70] [--run 1]
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
from .run_classroom import load_index, read_img

W, H, STEP_MS = 1920, 1080, 500
ENROL_IMGS = (0, 1, 2)
QUERY_POOL = list(range(12, 72))


def phone_background(rng):
    base = np.full((H, W, 3), 135, np.uint8).astype(np.float32)
    base += np.linspace(20, -20, H, dtype=np.float32)[:, None, None]
    for _ in range(5):
        x, y = rng.randint(0, W - 300), rng.randint(int(H * 0.6), H - 90)
        cv2.rectangle(base, (x, y), (x + rng.randint(160, 320), y + rng.randint(50, 90)),
                      (90, 86, 80), -1)
    return np.clip(base, 0, 255).astype(np.uint8)


def run(args):
    rng = random.Random(args.run * 7919 + 3)
    models = Path(args.models)
    runtime = Runtime(models / "manifest.json")
    model_hash = canonical_hash(runtime.manifest.model_dump())
    profile = load_profile(args.profile, model_hash)

    n_present, n_absent, n_intruder = args.present, 15, 3
    frames_n = args.frames

    with zipfile.ZipFile(args.zip) as archive:
        index = load_index(archive)
        ids = sorted(index)
        rng.shuffle(ids)
        present = ids[:n_present]
        intruders = ids[n_present:n_present + n_intruder]
        absent = ids[n_present + n_intruder:n_present + n_intruder + n_absent]
        roster_ids = sorted(set(present) | set(absent))

        def img112(name):
            im = read_img(archive, name)
            return im if im.shape[:2] == (112, 112) else cv2.resize(im, (112, 112))

        templates = {pid: np.stack([runtime.embed([img112(f"{pid}/{i}.png")])[0] for i in ENROL_IMGS])
                     for pid in set(roster_ids) | set(present)}

        def frame_face(pid, t):
            return read_img(archive, f"{pid}/{QUERY_POOL[(hash((pid, t)) % len(QUERY_POOL))]}.png")

        # Walk order: every present + intruder student is "passed" close-up.
        visited = present + intruders
        rng.shuffle(visited)
        # ~15% of students never present a usable face (look down / turned away / occluded).
        uncooperative = set() if args.steady else set(rng.sample(present, int(round(n_present * 0.15))))
        # each student centered on a frame, visible in a +/-2 band (teacher approaches & leaves)
        centre = {pid: 2 + int(i / max(1, len(visited) - 1) * (frames_n - 5))
                  for i, pid in enumerate(visited)}

        bg = phone_background(rng)
        frames, gt = [], []
        for t in range(frames_n):
            frame = bg.copy()
            here = [pid for pid in visited if abs(centre[pid] - t) <= args.dwell]
            rects = []
            slots = len(here)
            for k, pid in enumerate(here):
                near = centre[pid] == t                      # closest at the centre frame
                px = rng.randint(220, 300) if near else rng.randint(150, 210)
                if args.face_cap:  # 112px sources lose sharpness when enlarged far beyond ~180px
                    px = min(px, args.face_cap)
                cx = int(W * (k + 0.5) / max(1, slots)) + rng.randint(-30, 30)
                cy = int(H * 0.46) + rng.randint(-40, 40)
                face = frame_face(pid, t)
                bad = pid in uncooperative
                if bad:
                    # turned away / looking down: blur + lower-face occlusion
                    face = cv2.GaussianBlur(face, (0, 0), 3.0)
                    face[int(112 * 0.55):, :] = (90, 90, 95)
                light = rng.uniform(0.92, 1.12)
                f = cv2.resize(face, (px, px), interpolation=cv2.INTER_CUBIC)
                f = np.clip(f.astype(np.float32) * light, 0, 255).astype(np.uint8)
                x, y = max(0, min(W - px, int(cx - px / 2))), max(0, min(H - px, int(cy - px / 2)))
                frame[y:y + px, x:x + px] = f
                rects.append(((x, y, x + px, y + px), pid))
            # walking motion blur on ~25% of frames
            if rng.random() < 0.25 and not args.steady:
                frame = cv2.GaussianBlur(frame, (0, 0), 1.3)
            frame = np.clip(frame.astype(np.float32) +
                            np.random.default_rng(t).normal(0, 3, frame.shape), 0, 255).astype(np.uint8)
            ok, enc = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, 95 if args.steady else 80])
            frames.append(cv2.imdecode(enc, cv2.IMREAD_COLOR))
            gt.append(rects)

    roster = {i: templates[i] for i in roster_ids}
    hits, detections, rejects, confusions, crops_matched = [], 0, 0, 0, 0
    started = time.perf_counter()
    per_frame_ms = []
    for t, frame in enumerate(frames):
        f0 = time.perf_counter()
        faces = runtime.detect(frame, profile.detector_confidence, profile.nms_iou)
        detections += len(faces)
        for face in faces:
            cx, cy = face.box.reshape(2, 2).mean(axis=0)
            owner = next((pid for (x1, y1, x2, y2), pid in gt[t] if x1 <= cx <= x2 and y1 <= cy <= y2), None)
            if not quality(frame, face, profile):
                rejects += 1
                continue
            crop = safe_align(frame, face, defaultdict(float))
            if crop is None:
                continue
            who, score, margin = match(normalize(runtime.embed([crop])[0]), roster, profile)
            if who is not None:
                crops_matched += 1
                hits.append({"participant_id": who, "timestamp_ms": t * STEP_MS,
                             "similarity": score, "margin": margin})
                if owner is not None and who != owner and who in roster:
                    confusions += 1
        per_frame_ms.append((time.perf_counter() - f0) * 1000)
    proposals = {p["participant_id"] for p in corroborate(hits, profile)}

    present_set = set(present)
    recalled = present_set & proposals
    uncoop_recalled = uncooperative & proposals
    coop = present_set - uncooperative
    result = {
        "label": "SYNTHETIC phone-walkaround (DigiFace); not real classroom accuracy",
        "present": n_present, "roster": len(roster_ids), "absent_on_roster": n_absent,
        "intruders": n_intruder, "frames": frames_n, "dwell": args.dwell,
        "recall_overall": round(len(recalled) / n_present, 3),
        "recall_cooperative": round(len((coop & proposals)) / max(1, len(coop)), 3),
        "uncooperative_students": len(uncooperative),
        "uncooperative_recalled": len(uncoop_recalled),
        "missed": n_present - len(recalled),
        "false_presence": len(proposals - present_set - set(intruders)),
        "unknown_leak": len(proposals & set(intruders)),
        "identity_confusions": confusions,
        "detections": detections, "quality_rejects": rejects, "crops_matched": crops_matched,
        "wall_seconds": round(time.perf_counter() - started, 1),
        "frame_ms_median": round(float(np.median(per_frame_ms)), 1),
        "frame_ms_p95": round(float(np.percentile(per_frame_ms, 95)), 1),
        "run": args.run, "model_hash": model_hash,
        "profile_hash": canonical_hash(profile.model_dump()),
        "decision_digest": hashlib.sha256(json.dumps(sorted(proposals)).encode()).hexdigest(),
    }
    out = args.out / f"phone-walk-run{args.run}.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps(result, indent=2, sort_keys=True))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--zip", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--present", type=int, default=70)
    ap.add_argument("--frames", type=int, default=48)
    ap.add_argument("--dwell", type=int, default=2,
                    help="half-width of frames each student is visible; larger = slower walk / longer pause")
    ap.add_argument("--run", type=int, default=1)
    ap.add_argument("--steady", action="store_true",
                    help="Steady recording of cooperative students: no motion blur, light compression")
    ap.add_argument("--face-cap", type=int, default=0,
                    help="Optional maximum pasted face size in pixels (0 = unchanged behaviour)")
    ap.add_argument("--models", default=".local/spike/models/buffalo_sc")
    ap.add_argument("--profile", type=Path, default=Path(".local/spike/profiles/frozen-phase1b-v1.json"))
    run(ap.parse_args())


if __name__ == "__main__":
    main()
