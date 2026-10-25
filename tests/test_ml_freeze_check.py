"""Synthetic freeze-receipt contract; no private model or template material."""

import hashlib
import importlib.util
import json
from pathlib import Path

spec = importlib.util.spec_from_file_location("check_ml_freeze", Path("scripts/check_ml_freeze.py"))
freeze = importlib.util.module_from_spec(spec)
spec.loader.exec_module(freeze)


def test_freeze_detects_changed_file_and_missing_file(tmp_path):
    model = tmp_path / "synthetic.txt"
    model.write_bytes(b"synthetic fixture")
    receipt = tmp_path / "receipt.json"
    receipt.write_text(json.dumps({"frozen_files_sha256": {
        "synthetic.txt": hashlib.sha256(model.read_bytes()).hexdigest()}}))
    assert freeze.verify(receipt, tmp_path) == (1, 1)
    model.write_bytes(b"changed")
    assert freeze.verify(receipt, tmp_path) == (1, 0)
    model.unlink()
    assert freeze.verify(receipt, tmp_path) == (1, 0)
