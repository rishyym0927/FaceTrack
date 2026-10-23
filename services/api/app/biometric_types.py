import math
from typing import Literal
from uuid import UUID

from pydantic import Field, field_validator

from .schemas import Strict


class ConsentAccept(Strict):
    notice_version: str
    notice_hash: str = Field(pattern=r"^[a-f0-9]{64}$")


class EnrollmentCreate(Strict):
    consent_id: UUID
    mime_type: Literal["video/mp4", "video/webm"]
    expected_bytes: int = Field(gt=0, le=25 * 1024 * 1024)


class UploadComplete(Strict):
    asset_id: UUID
    byte_size: int = Field(gt=0, le=25 * 1024 * 1024)
    sha256: str = Field(pattern=r"^[a-f0-9]{64}$")


class Approval(Strict):
    identity_confirmed: Literal[True]
    poses_confirmed: Literal[True]


class Rejection(Strict):
    reason: str = Field(min_length=1, max_length=500)


class Epoch(Strict):
    epoch: int = Field(gt=0)


class WorkerFailure(Epoch):
    code: str = Field(pattern=r"^[A-Z0-9_]{1,80}$")
    retryable: bool = False


class Template(Strict):
    ordinal: int = Field(ge=0, le=4)
    pose: Literal["unverified"]
    vector: list[float] = Field(min_length=512, max_length=512)

    @field_validator("vector")
    @classmethod
    def unit_vector(cls, value):
        if not all(math.isfinite(x) for x in value) or abs(sum(x * x for x in value) - 1) > 0.01:
            raise ValueError("Expected finite normalized embedding")
        return value


class WorkerComplete(Epoch):
    generation: int = Field(gt=0)
    source_sha256: str = Field(pattern=r"^[a-f0-9]{64}$")
    processed_sha256: str = Field(pattern=r"^[a-f0-9]{64}$")
    model_hash: str = Field(pattern=r"^[a-f0-9]{64}$")
    profile_hash: str = Field(pattern=r"^[a-f0-9]{64}$")
    templates: list[Template] = Field(min_length=3, max_length=5)
    quality: dict[str, int] = Field(max_length=10)
    timings: dict[str, float] = Field(max_length=10)

    @field_validator("templates")
    @classmethod
    def ordinals(cls, value):
        if sorted(x.ordinal for x in value) != list(range(len(value))):
            raise ValueError("Ordinals must be unique and consecutive")
        return value

    @field_validator("quality")
    @classmethod
    def quality_bounds(cls, value):
        allowed = {"sampled_frames", "detections", "quality_rejects", "duplicate_frames"}
        if not set(value).issubset(allowed) or not all(0 <= x <= 100000 for x in value.values()):
            raise ValueError("Invalid quality counts")
        return value

    @field_validator("timings")
    @classmethod
    def timings_finite(cls, value):
        if not all(math.isfinite(x) and x >= 0 for x in value.values()):
            raise ValueError("Invalid timing")
        return value


class UploadMetadata(Strict):
    mime_type: Literal["video/mp4", "video/webm"]
    expected_bytes: int = Field(gt=0, le=25 * 1024 * 1024)
