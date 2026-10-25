#!/usr/bin/env python3
"""Check the private held-out freeze receipt without revealing file contents or hashes."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


def sha256(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(block)
    return hasher.hexdigest()


def verify(receipt: Path, root: Path) -> tuple[int, int]:
    data = json.loads(receipt.read_text())
    files = data["frozen_files_sha256"]
    if not isinstance(files, dict) or not files:
        raise ValueError("Missing frozen file map")
    passed = 0
    for relative, expected in files.items():
        path = root / relative
        if not isinstance(expected, str) or len(expected) != 64:
            raise ValueError("Invalid hash entry")
        if path.is_file() and not path.is_symlink() and sha256(path) == expected:
            passed += 1
    return len(files), passed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--receipt", type=Path,
                        default=Path(".local/spike/held-out-freeze-v2.json"))
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    try:
        total, passed = verify(args.receipt, args.root)
    except (OSError, ValueError, KeyError, TypeError):
        print("Freeze receipt unavailable or invalid. Ask the authorized demo operator.")
        return 2
    print(f"Frozen ML files: {passed}/{total} verified.")
    return 0 if passed == total else 1


if __name__ == "__main__":
    raise SystemExit(main())
