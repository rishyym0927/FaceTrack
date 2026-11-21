"""Dense recognition adapter: same gates and thresholds as the frozen pipeline, more frames."""

from types import SimpleNamespace

import numpy as np
import pytest

from facetrack_ml.config import Profile
from facetrack_ml.media import MediaInfo
from facetrack_ml.runtime import Face, quality
from facetrack_worker import dense

PROFILE = Profile(
    model_hash="a" * 64,
    calibration_id="test",
    identity_threshold=0.46,
    minimum_margin=0.14,
    enrollment_consistency=0.3,
    blur_variance=25.0,
)


def frame(seed, size=(480, 640)):
    return np.random.default_rng(seed).integers(0, 255, (*size, 3), dtype=np.uint8)


def face(x1=100, y1=100, x2=220, y2=220):
    box = np.array([x1, y1, x2, y2], dtype=np.float32)
    marks = np.array([[130, 140], [190, 140], [160, 170], [135, 200], [185, 200]], np.float32)
    return Face(box=box, landmarks=marks, confidence=0.9)


@pytest.mark.parametrize(
    "box,expected",
    [
        ((100, 100, 220, 220), None),
        ((-5, 100, 120, 220), "edge"),
        ((100, 100, 150, 150), "small"),
    ],
)
def test_reject_reason_agrees_with_the_frozen_gate(box, expected):
    f, fc = frame(1), face(*box)
    assert dense.reject_reason(f, fc, PROFILE) == expected
    assert (expected is None) == quality(f, fc, PROFILE)


def test_flat_and_dark_faces_are_named_blur_and_brightness():
    flat = np.full((480, 640, 3), 128, np.uint8)
    dark = np.zeros((480, 640, 3), np.uint8)
    assert dense.reject_reason(flat, face(), PROFILE) == "blur"
    assert dense.reject_reason(dark, face(), PROFILE) == "brightness"
    assert not quality(flat, face(), PROFILE) and not quality(dark, face(), PROFILE)


class Runtime:
    def __init__(self, visible):
        self.visible, self.queue, self.calls = visible, [], 0

    def detect(self, image, confidence, iou):
        index = self.calls
        self.calls += 1
        people = self.visible.get(index, [])
        self.queue.extend(people)
        return [face() for _ in people]

    def embed(self, crops):
        vectors = [np.eye(512, dtype=np.float32)[self.queue.pop(0)] for _ in crops]
        return np.stack(vectors)


class Roster:
    def load(self, people, model_hash, profile_hash):
        return {p: np.eye(512, dtype=np.float32)[i][None] for i, p in enumerate(people)}


def run(tmp_path, visible, duration=15, fps=4.0):
    clip = tmp_path / "clip.mp4"
    clip.write_bytes(b"x")
    requested = []

    def frames(path, info, count, timings):
        requested.append(count)
        for i in range(count):
            yield round(i * 1000 * info.duration / count), frame(i)

    info = MediaInfo(width=640, height=480, duration=duration, codec="h264", size=1)
    pipeline = SimpleNamespace(
        runtime=Runtime(visible),
        profile=PROFILE,
        model_hash="a" * 64,
        profile_hash="b" * 64,
        _times=lambda timings, started: timings,
    )
    original = dense.probe
    dense.probe = lambda path, enrollment=False: info
    try:
        result = dense.recognize(pipeline, clip, ["s0", "s1", "s2"], Roster(), fps, frames)
    finally:
        dense.probe = original
    return result, requested[0]


def test_samples_more_frames_than_the_frozen_twelve(tmp_path):
    result, requested = run(tmp_path, {})
    assert requested == 60  # 15 s x 4 fps, instead of the frozen 12
    assert result["quality"]["sampled_frames"] == 60 and result["sample_fps"] == 4.0
    assert dense.sample_fps() == 4.0


def test_short_clips_never_fall_below_the_frozen_coverage(tmp_path):
    _, requested = run(tmp_path, {}, duration=2)
    assert requested == 12


def test_recognition_and_plain_reasons_per_student(tmp_path):
    # s0 is seen in five frames, s1 in a single frame, s2 never.
    visible = {i: [0] for i in range(5)} | {10: [1]}
    result, _ = run(tmp_path, visible)
    assert [p["participant_id"] for p in result["proposals"]] == ["s0"]
    reasons = {d["student_id"]: d["reason"] for d in result["diagnostics"]}
    assert reasons == {"s0": "recognized", "s1": "seen_too_briefly", "s2": "not_seen"}
    assert result["face_px_median"] == 120 and result["reject_reasons"] == {}


def test_progress_runs_through_the_real_stages_in_order(tmp_path):
    steps = []
    visible = {i: [0] for i in range(10)}
    clip = tmp_path / "clip.mp4"
    clip.write_bytes(b"x")

    def frames(path, info, count, timings):
        for i in range(count):
            yield round(i * 1000 * info.duration / count), frame(i)

    info = MediaInfo(width=640, height=480, duration=15, codec="h264", size=1)
    pipeline = SimpleNamespace(
        runtime=Runtime(visible),
        profile=PROFILE,
        model_hash="a" * 64,
        profile_hash="b" * 64,
        _times=lambda timings, started: timings,
    )
    original = dense.probe
    dense.probe = lambda path, enrollment=False: info
    try:
        dense.recognize(
            pipeline, clip, ["s0", "s1", "s2"], Roster(), 4.0, frames,
            progress=lambda stage, percent=None: steps.append((stage, percent)),
        )
    finally:
        dense.probe = original
    order = [stage for i, (stage, _) in enumerate(steps) if i == 0 or stage != steps[i - 1][0]]
    assert order == ["detecting", "recognizing", "matching"]
    detecting = [p for s, p in steps if s == "detecting"]
    assert detecting[0] == 0 and detecting[-1] == 100 and detecting == sorted(detecting)
    recognizing = [p for s, p in steps if s == "recognizing"]
    assert recognizing[0] == 0 and recognizing[-1] == 100


def test_embedding_in_chunks_keeps_every_crop_in_order(tmp_path):
    # 40 usable faces forces several chunks; each must keep its own identity.
    visible = {i: [i % 3] for i in range(40)}
    clip = tmp_path / "clip.mp4"
    clip.write_bytes(b"x")

    def frames(path, info, count, timings):
        for i in range(count):
            yield round(i * 250), frame(i)

    info = MediaInfo(width=640, height=480, duration=10, codec="h264", size=1)
    runtime = Runtime(visible)
    pipeline = SimpleNamespace(runtime=runtime, profile=PROFILE, model_hash="a" * 64,
                               profile_hash="b" * 64, _times=lambda t, s: t)
    original = dense.probe
    dense.probe = lambda path, enrollment=False: info
    try:
        observations, *_ = dense.observe(pipeline, clip, 4.0, frames)
    finally:
        dense.probe = original
    assert len(observations) == 40
    identities = [int(np.argmax(vector)) for _, vector in observations]
    assert identities == [i % 3 for i in range(40)]
    assert [stamp for stamp, _ in observations] == sorted(stamp for stamp, _ in observations)
