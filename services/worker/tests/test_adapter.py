"""Synthetic media contract tests; these do not establish recognition accuracy."""

import subprocess

import pytest

from facetrack_ml.errors import SpikeError
from facetrack_ml.media import executable, probe
from facetrack_worker.inference import normalize_rotation


def video(path):
    subprocess.run(
        [
            executable("ffmpeg"),
            "-nostdin",
            "-v",
            "error",
            "-f",
            "lavfi",
            "-i",
            "color=c=gray:s=320x240:r=3",
            "-t",
            "10",
            "-c:v",
            "libx264",
            "-pix_fmt",
            "yuv420p",
            str(path),
        ],
        check=True,
        timeout=20,
    )
    return path


def test_native_rotation_is_explicit_and_bounded(tmp_path):
    source = video(tmp_path / "original.mp4")
    rotated = tmp_path / "rotated.mp4"
    subprocess.run(
        [
            executable("ffmpeg"),
            "-nostdin",
            "-v",
            "error",
            "-display_rotation:v:0",
            "90",
            "-i",
            str(source),
            "-c",
            "copy",
            str(rotated),
        ],
        check=True,
        timeout=20,
    )
    with pytest.raises(SpikeError, match="upright"):
        probe(rotated, enrollment=True)
    upright = normalize_rotation(rotated, tmp_path)
    info = probe(upright, enrollment=True)
    assert (info.width, info.height) == (240, 320)
    assert source.exists() and rotated.exists()


def test_audio_is_rejected_not_silently_stripped(tmp_path):
    source = video(tmp_path / "source.mp4")
    audio = tmp_path / "audio.mp4"
    subprocess.run(
        [
            executable("ffmpeg"),
            "-nostdin",
            "-v",
            "error",
            "-i",
            str(source),
            "-f",
            "lavfi",
            "-i",
            "sine=frequency=440",
            "-t",
            "10",
            "-c:v",
            "copy",
            "-c:a",
            "aac",
            str(audio),
        ],
        check=True,
        timeout=20,
    )
    with pytest.raises(SpikeError) as caught:
        normalize_rotation(audio, tmp_path)
    assert caught.value.code == "AUDIO_NOT_ALLOWED"


def test_corrupt_input_is_rejected(tmp_path):
    bad = tmp_path / "bad.webm"
    bad.write_bytes(b"not video")
    with pytest.raises(SpikeError):
        normalize_rotation(bad, tmp_path)
