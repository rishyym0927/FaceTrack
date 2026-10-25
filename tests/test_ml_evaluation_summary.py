"""Aggregate-only reporting tests; fixtures contain no biometric data."""

import importlib.util
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "summarize_ml_evaluation", Path("scripts/summarize_ml_evaluation.py")
)
summary = importlib.util.module_from_spec(spec)
spec.loader.exec_module(summary)


def run(proposals, false=(), missed=()):
    return {"status": "processed", "proposals": [{"participant_id": p} for p in proposals],
            "false_presence_proposals": list(false),
            "missed_present_identities": list(missed)}


def test_counts_unique_clips_not_fresh_process_repeats():
    report = {"status": "incomplete_or_failed", "missing_scenarios": ["variation"],
              "cases": [
                  {"scenario": "both_known", "runs": [run(["p01"], missed=["p02"])] * 3},
                  {"scenario": "unknown_only", "runs": [run(["p01"], false=["p01"])] * 3},
                  {"scenario": "no_face", "runs": [{"status": "processing_failed"}]},
              ]}
    result = summary.summarize(report)
    assert result["clips"] == 3 and result["processed"] == 2 and result["failed"] == 1
    assert result["true_proposals"] == 1 and result["false_proposals"] == 1
    assert result["misses"] == 1 and result["unknown_only_false_id_clips"] == 1
    assert result["proposal_precision"] == result["proposal_recall"] == 0.5
    assert result["unstable_repeat_clips"] == 0
    assert "p01" not in str(result)


def test_repeat_disagreement_is_visible_without_inflating_samples():
    report = {"cases": [{"scenario": "one_absent", "runs": [run(["p01"]), run([])]}]}
    result = summary.summarize(report)
    assert result["unstable_repeat_clips"] == 1
    assert result["true_proposals"] == 1
