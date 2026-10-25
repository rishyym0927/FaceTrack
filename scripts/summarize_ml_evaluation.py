#!/usr/bin/env python3
"""Summarize a private held-out report without printing participant identities.

Counts are identity opportunities in one run per clip, not classroom accuracy.
Fresh-process repeats are checked for stability but are not extra samples.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def summarize(report: dict) -> dict:
    cases = report.get("cases", [])
    counts = {"clips": len(cases), "processed": 0, "failed": 0,
              "true_proposals": 0, "false_proposals": 0, "misses": 0,
              "unknown_only_false_id_clips": 0, "no_face_false_id_clips": 0,
              "unstable_repeat_clips": 0}
    for case in cases:
        runs = case.get("runs", [])
        if not runs or runs[0].get("status") != "processed":
            counts["failed"] += 1
            continue
        counts["processed"] += 1
        first = runs[0]
        false_ids = set(first["false_presence_proposals"])
        proposed_ids = {p["participant_id"] for p in first["proposals"]}
        missed_ids = set(first["missed_present_identities"])
        counts["true_proposals"] += len(proposed_ids - false_ids)
        counts["false_proposals"] += len(false_ids)
        counts["misses"] += len(missed_ids)
        if case["scenario"] == "unknown_only" and false_ids:
            counts["unknown_only_false_id_clips"] += 1
        if case["scenario"] == "no_face" and false_ids:
            counts["no_face_false_id_clips"] += 1
        signature = (frozenset(proposed_ids), frozenset(false_ids), frozenset(missed_ids))
        if any(run.get("status") != "processed" or
               (frozenset(p["participant_id"] for p in run["proposals"]),
                frozenset(run["false_presence_proposals"]),
                frozenset(run["missed_present_identities"])) != signature
               for run in runs[1:]):
            counts["unstable_repeat_clips"] += 1
    tp, fp, fn = (counts[k] for k in ("true_proposals", "false_proposals", "misses"))
    counts["proposal_precision"] = round(tp / (tp + fp), 4) if tp + fp else None
    counts["proposal_recall"] = round(tp / (tp + fn), 4) if tp + fn else None
    counts["evaluation_status"] = report.get("status", "unknown")
    counts["missing_scenarios"] = report.get("missing_scenarios", [])
    counts["limitations"] = ["one_run_per_clip", "small_sample_not_production_accuracy",
                              "operator_ground_truth", "identity_set_not_face_attribution"]
    return counts


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path, help="Private evaluate_spike.py output JSON")
    args = parser.parse_args()
    try:
        report = json.loads(args.report.read_text())
        if report.get("dataset") != "test" or not isinstance(report.get("cases"), list):
            raise ValueError("Expected a held-out test report")
        result = summarize(report)
    except (OSError, ValueError, KeyError, TypeError):
        print("Could not summarize this held-out report; check its private path and format.")
        return 2
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
