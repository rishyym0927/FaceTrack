"""Child adapter maps malformed documents and unreadable video to non-retryable failures."""

import csv
import subprocess

from facetrack_ml.config import digest
from facetrack_worker import inference, tabular


class Pipe:
    def __init__(self):
        self.sent = []

    def send(self, value):
        self.sent.append(value)

    def close(self):
        pass


def test_csv_syntax_error_is_an_invalid_document(tmp_path, monkeypatch):
    source = tmp_path / "input.csv"
    source.write_text("x\n")

    def broken(path):
        raise csv.Error("field larger than field limit")

    monkeypatch.setattr(tabular, "parse_csv", broken)
    pipe = Pipe()
    expected = {"kind": "timetable", "source_sha256": digest(source)}
    inference.run_child(pipe, str(source), "m", "p", expected)
    assert pipe.sent == [{"ok": False, "code": "INVALID_DOCUMENT", "retryable": False}]


def test_ffmpeg_failure_is_invalid_media(tmp_path, monkeypatch):
    def bad_ffmpeg(*args, **kwargs):
        raise subprocess.CalledProcessError(1, ["ffmpeg"])

    monkeypatch.setattr(inference, "load_manifest", bad_ffmpeg)
    pipe = Pipe()
    inference.run_child(pipe, str(tmp_path / "input.video"), "m", "p", {"kind": "enrollment"})
    assert pipe.sent == [{"ok": False, "code": "INVALID_MEDIA", "retryable": False}]
