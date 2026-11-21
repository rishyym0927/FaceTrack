"""Regressions from the worker audit: stale unacked messages, parallel dense, memo, claiming."""

import time
from contextlib import contextmanager
from types import SimpleNamespace

import numpy as np
import pytest

from facetrack_ml.media import MediaInfo
from facetrack_ml.runtime import Face
from facetrack_worker import agent, dense, media_cache
from tests.test_dense import PROFILE


class FakeRedis:
    def __init__(self, queued, unacked_ages, zcount_fails=False):
        self.queued, self.ages, self.fail = queued, unacked_ages, zcount_fails

    def llen(self, key):
        return self.queued

    def hlen(self, key):
        return len(self.ages)

    def zcount(self, key, low, high):
        if self.fail:
            raise RuntimeError
        return sum(1 for age in self.ages if time.time() - age >= low)


def install(monkeypatch, redis):
    @contextmanager
    def connection():
        yield SimpleNamespace(default_channel=SimpleNamespace(client=redis))

    monkeypatch.setattr(agent.app, "connection_for_read", connection)


def test_backlog_ignores_unacked_messages_of_a_killed_worker(monkeypatch):
    install(monkeypatch, FakeRedis(0, [3600, 3000]))  # two messages an hour old
    assert agent.backlog() == 0
    install(monkeypatch, FakeRedis(1, [3600, 5]))
    assert agent.backlog() == 2  # one queued, one genuinely running


def test_backlog_falls_back_to_the_unacked_count(monkeypatch):
    install(monkeypatch, FakeRedis(0, [5, 5], zcount_fails=True))
    assert agent.backlog() == 2


class Reply:
    status_code = 200

    def json(self):
        return {"id": "j", "lease_epoch": 1}


def test_agent_claims_again_at_once_while_a_slot_is_free(monkeypatch):
    agent.PENDING.clear()
    monkeypatch.setattr(agent, "SLOTS", 2)
    monkeypatch.setattr(agent, "backlog", lambda: 0)
    monkeypatch.setattr(agent, "api", lambda c, m, p: Reply())
    monkeypatch.setattr(agent.app, "send_task", lambda n, args: None)
    assert agent.cycle(None, 1e18)[1] == 0.2
    monkeypatch.setattr(agent, "backlog", lambda: 1)
    assert agent.cycle(None, 1e18)[1] == 2  # that claim filled the last slot


def test_unexpected_error_does_not_kill_the_agent(monkeypatch):
    agent.PENDING.clear()
    monkeypatch.setattr(agent, "backlog", lambda: 0)

    def boom(c, m, p):
        raise RuntimeError("bug")

    monkeypatch.setattr(agent, "api", boom)
    assert agent.cycle(None, 1e18)[1] == 5


def test_media_memo_is_invalidated_when_the_file_changes(tmp_path):
    f = tmp_path / "a"
    f.write_bytes(b"one")
    calls = []
    assert media_cache.once("x", f, lambda: calls.append(1) or 1) == 1
    assert media_cache.once("x", f, lambda: calls.append(1) or 2) == 1
    f.write_bytes(b"longer")
    assert media_cache.once("x", f, lambda: calls.append(1) or 3) == 3
    assert len(calls) == 2


def face():
    box = np.array([100, 100, 220, 220], np.float32)
    marks = np.array([[130, 140], [190, 140], [160, 170], [135, 200], [185, 200]], np.float32)
    return Face(box=box, landmarks=marks, confidence=0.9)


class ContentRuntime:
    """Thread-safe and order-independent: output depends only on the pixels given."""

    def detect(self, image, confidence, iou):
        return [face() for _ in range(int(image[0, 0, 0]) % 3)]

    def embed(self, crops):
        return np.stack([np.eye(512, dtype=np.float32)[int(c.mean()) % 512] for c in crops])


def observe(tmp_path, threads):
    clip = tmp_path / "clip.mp4"
    clip.write_bytes(b"x")
    info = MediaInfo(width=640, height=480, duration=10, codec="h264", size=1)

    def frames(path, info, count, timings):
        for i in range(count):
            image = np.random.default_rng(i).integers(0, 255, (480, 640, 3), dtype=np.uint8)
            yield i * 250, image

    pipeline = SimpleNamespace(runtime=ContentRuntime(), profile=PROFILE)
    steps = []
    media_cache.once(("probe", False), clip, lambda: info)
    out = dense.observe(pipeline, clip, 4.0, frames, lambda s, p=None: steps.append((s, p)), threads)
    return out, steps


def test_parallel_observe_matches_the_serial_loop(tmp_path):
    (serial, _, s_stats, *_), s_steps = observe(tmp_path, 1)
    (parallel, _, p_stats, *_), p_steps = observe(tmp_path, 4)
    assert len(serial) > 10
    assert [t for t, _ in serial] == [t for t, _ in parallel]
    assert all(np.array_equal(a, b) for (_, a), (_, b) in zip(serial, parallel))
    assert s_stats == p_stats
    detecting = [p for s, p in p_steps if s == "detecting"]
    assert detecting == sorted(detecting) and detecting[-1] == 100


def test_prefetch_keeps_order_forwards_errors_and_stops_the_reader():
    assert list(dense.prefetched(iter(range(20)))) == list(range(20))

    def broken():
        yield 1
        raise RuntimeError("decode")

    with pytest.raises(RuntimeError):
        list(dense.prefetched(broken()))
    closed = []

    def endless():
        try:
            yield from range(10**6)
        finally:
            closed.append(True)

    gen = dense.prefetched(endless())
    next(gen)
    gen.close()
    assert closed == [True]


def test_worker_threads_environment(monkeypatch):
    monkeypatch.setenv("RECOGNITION_THREADS", "3")
    assert dense.worker_threads() == 3
    monkeypatch.setenv("RECOGNITION_THREADS", "99")
    assert dense.worker_threads() == dense.MAX_THREADS
    monkeypatch.setenv("RECOGNITION_THREADS", "junk")
    assert dense.worker_threads() == min(dense.MAX_THREADS, dense.available_cpus())
