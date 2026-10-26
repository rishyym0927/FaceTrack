"""Deterministic manifests and aggregate metrics for licensed offline datasets."""

from __future__ import annotations

import csv
import hashlib
import json
import random
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path

SCENARIOS = (
    "both_known",
    "one_absent",
    "unknown_only",
    "known_plus_unknown",
    "position_scale",
    "no_face",
)


def file_hash(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _opaque_id(value: str, *, seed: int, prefix: str) -> str:
    digest = hashlib.sha256(f"{seed}:{value}".encode()).hexdigest()[:16]
    return f"{prefix}_{digest}"


def build_digiface_manifest(
    index: dict[str, list[str]], *, seed: int = 26028, dataset_root: Path | None = None
) -> dict:
    """Select 200 identities and disjoint 3-reference/2-query files deterministically."""

    eligible = sorted(identity for identity, files in index.items() if len(files) >= 5)
    if len(eligible) < 200:
        raise ValueError("DigiFace index needs at least 200 identities with five images each.")
    chosen = random.Random(seed).sample(eligible, 200)
    records = []
    for position, identity in enumerate(chosen):
        files = sorted(index[identity])[:5]
        assets = []
        for relative_path in files:
            asset = {"asset_id": _opaque_id(relative_path, seed=seed, prefix="asset")}
            if dataset_root is not None:
                path = (dataset_root / relative_path).resolve()
                root = dataset_root.resolve()
                if root not in path.parents:
                    raise ValueError("Dataset paths must remain below dataset_root.")
                if not path.is_file():
                    raise ValueError(f"Dataset asset does not exist: {relative_path}")
                asset["sha256"] = file_hash(path)
            else:
                asset["sha256"] = "Not measured yet"
            assets.append(asset)
        records.append(
            {
                "identity_id": _opaque_id(identity, seed=seed, prefix="identity"),
                "split": "calibration" if position < 80 else "held_out",
                "enrolment": assets[:3],
                "queries": assets[3:5],
            }
        )
    scenes = [
        {
            "scene_id": f"{scenario}-{number:02d}",
            "scenario": scenario,
            "width": 1280,
            "height": 720,
            "seed": seed + offset * 10 + number,
        }
        for offset, scenario in enumerate(SCENARIOS)
        for number in range(10)
    ]
    return {
        "schema_version": 1,
        "seed": seed,
        "licence_scope": "non-commercial academic research; verify local dataset terms",
        "identities": records,
        "scenes": scenes,
        "results": "Not measured yet",
    }


@dataclass(frozen=True)
class AttendanceOutcome:
    video_id: str
    scenario: str
    identity: str
    expected_present: bool
    proposed_present: bool
    known_identity: bool
    assessed: bool


def attendance_metrics(rows: list[AttendanceOutcome]) -> dict[str, float | int | str]:
    """Aggregate identity outcomes without storing images, embeddings or personal data."""

    if not rows:
        return {"status": "Not measured yet", "samples": 0}
    tp = sum(r.expected_present and r.proposed_present for r in rows)
    fp = sum(not r.expected_present and r.proposed_present for r in rows)
    fn = sum(r.expected_present and not r.proposed_present and r.assessed for r in rows)
    assessed = sum(r.assessed for r in rows)
    unknown_false_ids = sum(not r.known_identity and r.proposed_present for r in rows)
    by_video: dict[str, int] = defaultdict(int)
    for row in rows:
        if not row.expected_present and row.proposed_present:
            by_video[row.video_id] += 1
    return {
        "status": "measured",
        "samples": len(rows),
        "proposed_present_precision": tp / (tp + fp) if tp + fp else 0.0,
        "proposed_present_recall": tp / (tp + fn) if tp + fn else 0.0,
        "unknown_false_identifications": unknown_false_ids,
        "absent_false_presence": fp,
        "videos_with_false_presence": len(by_video),
        "coverage": assessed / len(rows),
        "unassessed_rate": 1 - assessed / len(rows),
    }


def write_frozen_manifest(manifest: dict, destination: Path) -> str:
    destination.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(manifest, indent=2, sort_keys=True) + "\n"
    destination.write_text(payload)
    return hashlib.sha256(payload.encode()).hexdigest()


def write_aggregate_results(rows: list[AttendanceOutcome], destination: Path) -> tuple[Path, Path]:
    """Write Git-safe aggregate JSON/CSV without identities or participant-level rows."""

    destination.mkdir(parents=True, exist_ok=True)
    grouped: dict[str, list[AttendanceOutcome]] = defaultdict(list)
    for row in rows:
        grouped[row.scenario].append(row)
    payload = {
        "schema_version": 1,
        "overall": attendance_metrics(rows),
        "by_scenario": {
            scenario: attendance_metrics(grouped[scenario]) for scenario in sorted(grouped)
        },
    }
    json_path = destination / "aggregate.json"
    csv_path = destination / "aggregate.csv"
    json_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    fieldnames = ["scenario", *attendance_metrics(rows).keys()]
    with csv_path.open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerow({"scenario": "all", **payload["overall"]})
        for scenario, metrics in payload["by_scenario"].items():
            writer.writerow({"scenario": scenario, **metrics})
    return json_path, csv_path
