#!/usr/bin/env python3
"""Run independent CLI processes against an operator-labelled, private clip suite.

This compares proposed identity sets, not per-face attribution or production accuracy.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path
from typing import Annotated, Literal

from facetrack_ml.capture import validate_capture
from facetrack_ml.config import StrictModel, canonical_hash, digest, read_json
from facetrack_ml.errors import SpikeError
from facetrack_ml.store import atomic_private_write
from pydantic import Field, ValidationError


class Case(StrictModel):
    case_id: str = Field(pattern=r"^[a-z0-9_-]{1,50}$")
    scenario: Literal["both_known", "one_absent", "unknown_only", "mixed_unknown",
                      "variation", "no_face"]
    video: str
    metadata: str
    expected_present: list[str]


class Suite(StrictModel):
    schema_version: Literal[1] = 1
    dataset: Literal["calibration", "test"]
    roster: list[str]
    # List ALL reference clips, and also ALL calibration clips for a test suite.
    excluded_videos: list[str] = Field(default_factory=list)
    # Preserve exclusions after the 24h raw-media cleanup, using the frozen receipt.
    excluded_media_sha256: list[Annotated[str, Field(pattern=r"^[0-9a-f]{64}$")]] = Field(
        default_factory=list)
    cases: list[Case] = Field(min_length=1, max_length=30)


def prepare(suite_path: Path, profile: Path) -> tuple[Suite, dict]:
    try:
        suite = Suite.model_validate(read_json(suite_path))
    except ValidationError as e:
        raise SpikeError("INVALID_SUITE", "Evaluation suite does not satisfy its contract.") from e
    from facetrack_ml.store import participant_id
    for person in suite.roster:
        participant_id(person)
    if len(suite.roster) < 2 or len(set(suite.roster)) != len(suite.roster):
        raise SpikeError("INVALID_SUITE", "Evaluation requires a distinct enrolled roster.")
    excluded = set(suite.excluded_media_sha256) | {
        digest(suite_path.parent / p) for p in suite.excluded_videos}
    if len(excluded) < 2:
        raise SpikeError("INVALID_SUITE", "Declare at least two distinct reference exclusions.")
    seen, ids, cases = set(), set(), []
    for case in suite.cases:
        if (case.case_id in ids or len(set(case.expected_present)) != len(case.expected_present)
                or not set(case.expected_present) <= set(suite.roster)):
            raise SpikeError("INVALID_SUITE", "Case IDs and expected roster identities must be valid.")
        if ((case.scenario in {"unknown_only", "no_face"} and case.expected_present)
                or (case.scenario == "both_known"
                    and set(case.expected_present) != set(suite.roster))
                or (case.scenario == "one_absent"
                    and len(case.expected_present) != len(suite.roster) - 1)):
            raise SpikeError("INVALID_SUITE", "Ground truth contradicts the case scenario.")
        ids.add(case.case_id)
        pair = validate_capture(suite_path.parent / case.video, suite_path.parent / case.metadata)
        if pair["metadata"]["dataset"] != suite.dataset:
            raise SpikeError("DATASET_MISMATCH", "Use separate calibration and held-out exports.")
        sha = pair["media_sha256"]
        if sha in excluded or sha in seen:
            raise SpikeError("DATASET_LEAKAGE", "Reference/calibration clips or duplicate cases reused.")
        seen.add(sha)
        cases.append({"case_id": case.case_id, "media_sha256": sha,
                      "metadata_sha256": pair["metadata_sha256"]})
    receipt = {"suite_hash": canonical_hash(suite.model_dump()),
               "profile_file_sha256": digest(profile), "cases": cases,
               "excluded_media_sha256": sorted(excluded)}
    return suite, receipt


def compare(result: dict, expected: list[str]) -> dict:
    proposed = {p["participant_id"] for p in result["proposals"]}
    truth = set(expected)
    return {"false_presence_proposals": sorted(proposed - truth),
            "missed_present_identities": sorted(truth - proposed),
            "identity_set_matches": proposed == truth}


def evaluate(suite_path: Path, profile: Path, manifest: Path, data_root: Path,
             out: Path, repeats: int) -> dict:
    if not 1 <= repeats <= 5:
        raise SpikeError("INVALID_RUN_COUNT", "Use one to five fresh-process runs per case.")
    suite, receipt = prepare(suite_path, profile)
    lock = out.with_suffix(".lock.json")
    if out.exists() or lock.exists():
        raise SpikeError("EVALUATION_EXISTS", "Use a new output name for each evaluation.")
    receipt["manifest_file_sha256"] = digest(manifest)
    receipt["repeats"] = repeats
    # Persist the chosen inputs BEFORE any test inference. Never overwrite prior evidence.
    atomic_private_write(lock, json.dumps(receipt, indent=2).encode())
    report = {"status": "running", "dataset": suite.dataset, "receipt": receipt, "cases": [],
              "limitations": ["identity_set_comparison_only", "operator_ground_truth",
                              "mixed_unknown_face_attribution_requires_human_review",
                              "small_sample_not_production_accuracy"]}
    atomic_private_write(out, json.dumps(report, indent=2).encode())
    for case_index, case in enumerate(suite.cases):
        runs = []
        for _ in range(repeats):
            if (digest(profile) != receipt["profile_file_sha256"]
                    or digest(manifest) != receipt["manifest_file_sha256"]
                    or digest(suite_path.parent / case.video)
                    != receipt["cases"][case_index]["media_sha256"]
                    or digest(suite_path.parent / case.metadata)
                    != receipt["cases"][case_index]["metadata_sha256"]):
                report["status"] = "evaluation_input_changed"
                atomic_private_write(out, json.dumps(report, indent=2).encode())
                raise SpikeError("EVALUATION_INPUT_CHANGED", "An input changed during evaluation.")
            command = [sys.executable, "-m", "facetrack_ml.cli", "--data-root", str(data_root),
                       "recognize", str(suite_path.parent / case.video), "--manifest", str(manifest),
                       "--profile", str(profile), "--roster", *suite.roster]
            start = time.perf_counter()
            try:
                process = subprocess.run(command, capture_output=True, timeout=600)
                wall_ms = round((time.perf_counter() - start) * 1000, 3)
                if process.returncode:
                    # Do not copy native stderr, which may contain local paths.
                    runs.append({"status": "processing_failed", "wall_ms": wall_ms})
                    continue
                result = json.loads(process.stdout)
                runs.append({"status": "processed", **compare(result, case.expected_present),
                             "proposals": result["proposals"],
                             "unknown_observations": result["unknown_observations"],
                             "quality": result["quality"], "timings": result["timings"],
                             "wall_ms": wall_ms})
            except (subprocess.TimeoutExpired, ValueError, KeyError):
                runs.append({"status": "processing_failed"})
        report["cases"].append({"case_id": case.case_id, "scenario": case.scenario, "runs": runs})
        atomic_private_write(out, json.dumps(report, indent=2, allow_nan=False).encode())
    scenarios = {case.scenario for case in suite.cases}
    required = {"both_known", "one_absent", "unknown_only", "mixed_unknown", "variation", "no_face"}
    report["missing_scenarios"] = sorted(required - scenarios)
    checks_passed = not report["missing_scenarios"] and all(
        run.get("identity_set_matches", False) for case in report["cases"] for run in case["runs"])
    report["status"] = ("checks_passed_pending_human_review" if checks_passed else "incomplete_or_failed")
    atomic_private_write(out, json.dumps(report, indent=2, allow_nan=False).encode())
    return {"status": report["status"], "case_count": len(suite.cases),
            "missing_scenarios": report["missing_scenarios"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for flag in ("suite", "profile", "manifest", "data-root", "out"):
        parser.add_argument("--" + flag, type=Path, required=True)
    parser.add_argument("--repeats", type=int, default=3)
    args = parser.parse_args()
    try:
        result = evaluate(args.suite, args.profile, args.manifest,
                          args.data_root, args.out, args.repeats)
        print(json.dumps(result))
        return 0 if result["status"] == "checks_passed_pending_human_review" else 1
    except SpikeError as error:
        print(json.dumps({"error": {"code": error.code, "message": str(error)}}), file=sys.stderr)
        return 2
    except (OSError, ValueError):
        print(json.dumps({"error": {"code": "INVALID_INPUT", "message":
                                   "Check private suite paths and JSON inputs."}}), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
