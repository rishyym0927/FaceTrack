import os
import time

import numpy as np
import pytest
from facetrack_ml.config import Profile
from facetrack_ml.errors import SpikeError
from facetrack_ml.pipeline import corroborate, match
from facetrack_ml.runtime import normalize
from facetrack_ml.store import TemplateStore, cleanup_media

MODEL = "a" * 64
PROFILE = "b" * 64


@pytest.fixture
def profile():
    return Profile(model_hash=MODEL, calibration_id="synthetic-unit-fixture",
                   identity_threshold=0.8, minimum_margin=0.1, enrollment_consistency=0.7)


def basis(index):
    value = np.zeros(512, dtype=np.float32)
    value[index] = 1
    return value


def test_matching_unknown_margin_and_distinct_identity(profile):
    roster = {"p01": np.stack([basis(0)] * 5), "p02": np.stack([basis(1)] * 5)}
    assert match(basis(0), roster, profile)[0] == "p01"
    assert match(basis(2), roster, profile)[0] is None
    assert match(normalize(basis(0) + basis(1)), roster, profile)[0] is None
    with pytest.raises(SpikeError, match="two identities"):
        match(basis(0), {"p01": roster["p01"]}, profile)


def test_temporal_confirmation_and_same_frame_conflict(profile):
    hit = {"participant_id": "p01", "timestamp_ms": 100, "similarity": 0.9}
    assert corroborate([hit], profile) == []
    assert corroborate([hit, {**hit, "timestamp_ms": 400}], profile) == []
    assert len(corroborate([hit, {**hit, "timestamp_ms": 700}], profile)) == 1
    assert corroborate([hit, hit, {**hit, "timestamp_ms": 700}], profile) == []


def test_normalization_rejects_zero_and_nonfinite():
    for value in [np.zeros(512), np.full(512, np.nan), np.full(512, np.inf)]:
        with pytest.raises(SpikeError):
            normalize(value)


def test_store_encrypts_authenticates_and_revokes(tmp_path):
    store = TemplateStore(tmp_path / "templates")
    for person, index in [("p01", 0), ("p02", 1)]:
        store.save(person, np.stack([basis(index)] * 3), MODEL, PROFILE)
    assert b'"vectors"' not in store.path("p01").read_bytes()
    assert (store.root / "template.key").stat().st_mode & 0o077 == 0
    loaded = store.load(["p01", "p02"], MODEL, PROFILE)
    np.testing.assert_allclose(loaded["p01"][0], basis(0))
    with pytest.raises(SpikeError) as error:
        store.load(["p01", "p02"], "c" * 64, PROFILE)
    assert error.value.code == "TEMPLATE_VERSION_MISMATCH"
    damaged = bytearray(store.path("p01").read_bytes())
    damaged[-1] ^= 1
    store.path("p01").write_bytes(damaged)
    with pytest.raises(SpikeError) as error:
        store.load(["p01", "p02"], MODEL, PROFILE)
    assert error.value.code == "TEMPLATE_UNAVAILABLE"
    store.revoke("p01")
    assert not store.path("p01").exists()


def test_store_rejects_unsafe_ids_and_duplicate_enrolment(tmp_path):
    store = TemplateStore(tmp_path)
    with pytest.raises(SpikeError):
        store.save("../x", np.stack([basis(0)] * 3), MODEL, PROFILE)
    store.save("p01", np.stack([basis(0)] * 3), MODEL, PROFILE)
    with pytest.raises(SpikeError) as error:
        store.save("p01", np.stack([basis(0)] * 3), MODEL, PROFILE)
    assert error.value.code == "ALREADY_ENROLLED"


def test_cleanup_only_expired_managed_media_and_no_symlinks(tmp_path):
    media = tmp_path / "media"
    media.mkdir()
    old, recent, key = media / "old.webm", media / "recent.mp4", media / "template.key"
    for p in [old, recent, key]:
        p.write_bytes(b"fixture")
    before = time.time() - 25 * 3600
    os.utime(old, (before, before))
    os.utime(key, (before, before))
    link = media / "link.webm"
    link.symlink_to(old)
    assert cleanup_media(media) == 1
    assert recent.exists() and key.exists() and link.is_symlink()
