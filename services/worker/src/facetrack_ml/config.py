from __future__ import annotations

import hashlib
import json
import math
from pathlib import Path
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, ValidationError

from .errors import SpikeError


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid", allow_inf_nan=False)


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def canonical_hash(value: dict) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"),
                                     allow_nan=False).encode()).hexdigest()


class Artifact(StrictModel):
    file: str
    sha256: str = Field(pattern=r"^[0-9a-f]{64}$")
    source_url: str
    input_name: str
    output_names: list[str]


class LicenseEvidence(StrictModel):
    status: Literal["unreviewed", "approved"] = "unreviewed"
    intended_use: Literal["local_poc"] = "local_poc"
    evidence_file: str | None = None
    evidence_sha256: str | None = None
    reviewed_by: str | None = None
    reviewed_at: str | None = None
    permitted_uses: list[str] = []


class ModelManifest(StrictModel):
    schema_version: Literal[1] = 1
    release_id: str
    detector_family: Literal["SCRFD"] = "SCRFD"
    recognizer_family: Literal["ArcFace-MobileFaceNet"] = "ArcFace-MobileFaceNet"
    detector: Artifact
    recognizer: Artifact
    detector_size: Literal[640] = 640
    detector_mean: float = 127.5
    detector_scale: float = 128.0
    recognizer_mean: float = 127.5
    recognizer_scale: float = 127.5
    dimension: Literal[512] = 512
    alignment: Literal["arcface-112-five-point-v1"] = "arcface-112-five-point-v1"
    license: LicenseEvidence


class Profile(StrictModel):
    schema_version: Literal[1] = 1
    model_hash: str = Field(pattern=r"^[0-9a-f]{64}$")
    calibration_id: str = Field(min_length=1, max_length=100)
    identity_threshold: float = Field(ge=-1, le=1)
    minimum_margin: float = Field(gt=0, le=2)
    enrollment_consistency: float = Field(ge=-1, le=1)
    detector_confidence: float = Field(default=0.6, gt=0, lt=1)
    nms_iou: float = Field(default=0.4, gt=0, lt=1)
    min_face_pixels: int = Field(default=80, ge=40, le=512)
    blur_variance: float = Field(default=40.0, ge=0)
    min_hits: int = Field(default=2, ge=2)
    min_span_ms: int = Field(default=500, ge=500)
    max_templates: Literal[5] = 5


def read_json(path: Path) -> dict:
    try:
        value = json.loads(path.read_text())
        if not isinstance(value, dict):
            raise ValueError()
        return value
    except (OSError, ValueError) as e:
        raise SpikeError("INVALID_CONFIG", "Cannot read a valid JSON configuration object.") from e


def load_manifest(path: Path, *, check_artifacts: bool = True) -> ModelManifest:
    try:
        manifest = ModelManifest.model_validate(read_json(path))
    except ValidationError as e:
        raise SpikeError("INVALID_MANIFEST", "Manifest fields do not satisfy the model contract.") from e
    permission = manifest.license
    if (permission.status != "approved" or "local_poc" not in permission.permitted_uses
            or not permission.reviewed_by or not permission.reviewed_at
            or not permission.evidence_file or not permission.evidence_sha256):
        raise SpikeError("MODEL_PERMISSION_REQUIRED",
                         "Document permitted local use and licence evidence before loading weights.")
    evidence = (path.parent / permission.evidence_file).resolve()
    if not evidence.is_file() or digest(evidence) != permission.evidence_sha256:
        raise SpikeError("LICENSE_EVIDENCE_MISMATCH", "Licence evidence is missing or changed.")
    if not all(math.isfinite(x) and x > 0 for x in
               (manifest.detector_scale, manifest.recognizer_scale)):
        raise SpikeError("INVALID_MANIFEST", "Normalization scales must be finite and positive.")
    if check_artifacts:
        for artifact in (manifest.detector, manifest.recognizer):
            artifact_path = (path.parent / artifact.file).resolve()
            if not artifact_path.is_file() or digest(artifact_path) != artifact.sha256:
                raise SpikeError("MODEL_HASH_MISMATCH", "A model artifact is missing or changed.")
    return manifest


def load_profile(path: Path, model_hash: str) -> Profile:
    try:
        profile = Profile.model_validate(read_json(path))
    except ValidationError as e:
        raise SpikeError("INVALID_PROFILE", "Profile must contain explicit calibrated values.") from e
    if profile.model_hash != model_hash:
        raise SpikeError("PROFILE_MODEL_MISMATCH", "The profile belongs to another model release.")
    return profile
