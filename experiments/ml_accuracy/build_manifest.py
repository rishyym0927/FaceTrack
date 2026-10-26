"""Create a Git-safe DigiFace experiment manifest from a local JSON index."""

import argparse
import json
from pathlib import Path

from .harness import build_digiface_manifest, write_frozen_manifest


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("index", type=Path, help="JSON object: identity -> local relative image paths")
    parser.add_argument("output", type=Path)
    parser.add_argument("--dataset-root", type=Path)
    parser.add_argument("--seed", type=int, default=26028)
    args = parser.parse_args()
    manifest = build_digiface_manifest(
        json.loads(args.index.read_text()), seed=args.seed, dataset_root=args.dataset_root
    )
    print(write_frozen_manifest(manifest, args.output))


if __name__ == "__main__":
    main()
