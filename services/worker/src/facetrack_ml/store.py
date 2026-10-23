from __future__ import annotations

import json
import os
import re
import tempfile
import time
from pathlib import Path

import numpy as np
from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from .errors import SpikeError
from .runtime import normalize

ID_PATTERN = re.compile(r"^p[0-9]{2,4}$")


def participant_id(value: str) -> str:
    if not ID_PATTERN.fullmatch(value):
        raise SpikeError("INVALID_PARTICIPANT_ID", "Use pseudonymous IDs such as p01 or p002.")
    return value


def private_directory(path: Path):
    if path.is_symlink():
        raise SpikeError("UNSAFE_PATH", "Local data directories must not be symlinks.")
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    path.chmod(0o700)


def atomic_private_write(path: Path, value: bytes):
    private_directory(path.parent)
    fd, temp = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(value)
        os.chmod(temp, 0o600)
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


class TemplateStore:
    def __init__(self, root: Path):
        if root.is_symlink():
            raise SpikeError("UNSAFE_PATH", "Template directory must not be a symlink.")
        self.root = root.resolve()
        private_directory(self.root)

    def _key(self, create: bool) -> bytes:
        path = self.root / "template.key"
        if path.is_symlink():
            raise SpikeError("UNSAFE_PATH", "Key must not be a symlink.")
        if not path.exists():
            if not create or any(self.root.glob("p*.enc")):
                raise SpikeError("KEY_MISSING", "Template key is missing; do not regenerate over data.")
            # Exclusive creation protects simultaneous first-time enrolments.
            try:
                fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                with os.fdopen(fd, "wb") as stream:
                    stream.write(AESGCM.generate_key(bit_length=256))
            except FileExistsError:
                pass
        if path.stat().st_mode & 0o077:
            raise SpikeError("UNSAFE_KEY_PERMISSIONS", "Template key must be readable only by its owner.")
        key = path.read_bytes()
        if len(key) != 32:
            raise SpikeError("INVALID_KEY", "Template key must contain 32 bytes.")
        return key

    def save(self, person: str, vectors: np.ndarray, model_hash: str, profile_hash: str):
        participant_id(person)
        if self.path(person).exists():
            raise SpikeError("ALREADY_ENROLLED", "Revoke the old local set before re-enrolling.")
        vectors = normalize(vectors)
        if vectors.ndim != 2 or vectors.shape[1] != 512 or not 3 <= len(vectors) <= 5:
            raise SpikeError("INVALID_TEMPLATES", "Expected three to five 512D templates.")
        payload = json.dumps({"schema_version": 1, "participant_id": person,
                              "model_hash": model_hash, "profile_hash": profile_hash,
                              "vectors": vectors.tolist(), "created_at": time.time()},
                             allow_nan=False).encode()
        nonce = os.urandom(12)
        encrypted = AESGCM(self._key(True)).encrypt(nonce, payload, person.encode())
        atomic_private_write(self.path(person), nonce + encrypted)

    def path(self, person: str) -> Path:
        return self.root / f"{participant_id(person)}.enc"

    def load(self, people: list[str], model_hash: str, profile_hash: str) -> dict[str, np.ndarray]:
        if len(set(people)) != len(people) or len(people) < 2:
            raise SpikeError("INVALID_ROSTER", "Provide at least two distinct enrolled identities.")
        key = self._key(False)
        result = {}
        for person in people:
            path = self.path(person)
            try:
                if path.is_symlink():
                    raise ValueError()
                data = path.read_bytes()
                payload = json.loads(AESGCM(key).decrypt(data[:12], data[12:], person.encode()))
                if (payload["participant_id"] != person or payload["model_hash"] != model_hash
                        or payload["profile_hash"] != profile_hash):
                    raise SpikeError("TEMPLATE_VERSION_MISMATCH",
                                     "Templates were enrolled under another model/profile.")
                vectors = normalize(np.asarray(payload["vectors"], dtype=np.float32))
                if vectors.ndim != 2 or vectors.shape[1] != 512 or not 3 <= len(vectors) <= 5:
                    raise ValueError()
                result[person] = vectors
            except SpikeError:
                raise
            except (OSError, ValueError, KeyError, InvalidTag) as e:
                raise SpikeError("TEMPLATE_UNAVAILABLE", "A template is missing or fails integrity.") from e
        return result

    def revoke(self, person: str):
        self.path(person).unlink(missing_ok=True)


def cleanup_media(root: Path, *, now: float | None = None) -> int:
    """Only this managed raw-media directory is eligible; never recurse/follow symlinks."""
    if root.is_symlink():
        raise SpikeError("UNSAFE_PATH", "Refusing cleanup through a symlink.")
    private_directory(root)
    cutoff = (time.time() if now is None else now) - 24 * 3600
    count = 0
    for path in root.iterdir():
        if (not path.is_symlink() and path.is_file() and
                path.suffix.lower() in {".webm", ".mp4", ".mov", ".json"}
                and path.stat().st_mtime <= cutoff):
            path.unlink()
            count += 1
    return count
