"""Ideal "teacher records each student properly" synthetic test. Research only.

One person per clip, centred, front-facing, bright and sharp, with natural variation drawn from
the person's many DigiFace renders (never the three enrolment images). Genuine clips are scored
against a 30-person roster; stranger clips use people who are NOT enrolled. The frozen model,
profile, quality gate, matcher and corroboration are unchanged. SYNTHETIC BENCHMARK, not
classroom accuracy.

    python -m experiments.ml_accuracy.run_individual --zip Z --out DIR [--people 300 --strangers 100]
"""

from __future__ import annotations

import argparse
import json
import random
import zipfile
from collections import defaultdict
from pathlib import Path

import cv2
import numpy as np
from facetrack_ml.config import canonical_hash, load_profile
from facetrack_ml.runtime import Runtime

from .run_ideal import FRAMES, ROSTER, evaluate

ENROL = (0, 1, 2)
QUERY_POOL = list(range(12, 72))
SIZES = (130, 180)


def clip(images, size):
    frames, truths = [], []
    for image in images:
        frame = np.full((720, 1280, 3), 120, np.uint8)
        x, y = (1280 - size) // 2, (720 - size) // 2
        frame[y:y + size, x:x + size] = cv2.resize(image, (size, size), interpolation=cv2.INTER_CUBIC)
        ok, enc = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, 95])
        frames.append(cv2.imdecode(enc, cv2.IMREAD_COLOR))
        truths.append([(x, y, x + size, y + size, True)])
    return frames, truths


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--zip", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--people", type=int, default=300)
    parser.add_argument("--strangers", type=int, default=100)
    parser.add_argument("--seed", type=int, default=2710)
    parser.add_argument("--roster", type=int, default=ROSTER)
    parser.add_argument("--models", default=".local/spike/models/buffalo_sc")
    parser.add_argument("--profile", type=Path,
                        default=Path(".local/spike/profiles/frozen-phase1b-v1.json"))
    args = parser.parse_args()

    runtime = Runtime(Path(args.models) / "manifest.json")
    profile = load_profile(args.profile, canonical_hash(runtime.manifest.model_dump()))
    rng = random.Random(args.seed)
    with zipfile.ZipFile(args.zip) as archive:
        folders = sorted({n.rsplit("/", 1)[0] for n in archive.namelist() if n.endswith(".png")},
                         key=lambda s: int(s))
        chosen = rng.sample(folders, args.people + args.strangers)
        enrolled, strangers = chosen[:args.people], chosen[args.people:]

        def read(folder, index):
            data = archive.read(f"{folder}/{index}.png")
            img = cv2.imdecode(np.frombuffer(data, np.uint8), cv2.IMREAD_COLOR)
            return img if img.shape[:2] == (112, 112) else cv2.resize(img, (112, 112))

        templates = {f: np.stack([runtime.embed([read(f, i)])[0] for i in ENROL]) for f in enrolled}
        rows = defaultdict(lambda: defaultdict(int))
        for size in SIZES:
            for who in enrolled:
                roster_ids = sorted(set(rng.sample(enrolled, args.roster - 1)) | {who})
                images = [read(who, i) for i in rng.sample(QUERY_POOL, FRAMES)]
                frames, truths = clip(images, size)
                proposals, m = evaluate(runtime, profile, {i: templates[i] for i in roster_ids},
                                        frames, truths)
                r = rows[size]
                r["genuine_clips"] += 1
                r["found"] += who in proposals
                r["wrong_person_marked"] += len(proposals - {who})
                r["usable_frames"] += m["usable"]
                r["total_frames"] += m["gt"]
            for who in strangers:
                roster_ids = sorted(rng.sample(enrolled, args.roster))
                images = [read(who, i) for i in rng.sample(QUERY_POOL, FRAMES)]
                frames, truths = clip(images, size)
                proposals, _ = evaluate(runtime, profile, {i: templates[i] for i in roster_ids},
                                        frames, truths)
                rows[size]["stranger_clips"] += 1
                rows[size]["stranger_marked_present"] += bool(proposals)
            r = rows[size]
            print(f"size {size}px: recognised {r['found']}/{r['genuine_clips']}  "
                  f"wrong-person {r['wrong_person_marked']}  "
                  f"strangers marked present {r['stranger_marked_present']}/{r['stranger_clips']}  "
                  f"usable frames {r['usable_frames']}/{r['total_frames']}", flush=True)
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / "individual_results.json").write_text(json.dumps(
        {"label": "SYNTHETIC BENCHMARK (DigiFace, one person per clip, ideal); not classroom accuracy",
         "people": args.people, "strangers": args.strangers, "roster": args.roster,
         "by_face_size": {str(k): dict(v) for k, v in rows.items()}}, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
