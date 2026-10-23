"""Validate operator-paired browser exports; sidecars never prove pose or identity."""
from __future__ import annotations

from pathlib import Path
from typing import Literal

from pydantic import Field, ValidationError, model_validator

from .config import StrictModel, digest, read_json
from .errors import SpikeError
from .media import probe


class CaptureMetadata(StrictModel):
    schema_version: Literal[1]
    capture_id: str = Field(pattern=r"^[0-9]{13}$")
    mode: Literal["enrollment", "classroom"]
    participant_id: str = Field(pattern=r"^p[0-9]{2,4}$")
    dataset: Literal["reference", "calibration", "test"]
    duration_seconds: int = Field(ge=1, le=30, strict=True)
    pose_prompts: list[str]
    audio_enabled: Literal[False]
    consent_confirmed: Literal[True]
    pose_verification: Literal["human_review_required"]

    @model_validator(mode="after")
    def coherent(self):
        if self.mode == "enrollment":
            if (self.dataset != "reference" or len(self.pose_prompts) != 5
                    or set(self.pose_prompts) != {"front", "up", "down", "left", "right"}
                    or self.pose_prompts[0] != "front" or self.duration_seconds < 15):
                raise ValueError("Invalid guided enrolment metadata")
        elif self.dataset == "reference" or self.pose_prompts or self.duration_seconds < 5:
            raise ValueError("Invalid classroom metadata")
        return self


def validate_capture(video: Path, metadata: Path, *, participant: str | None = None) -> dict:
    if metadata.is_symlink() or not metadata.is_file() or metadata.stat().st_size > 16384:
        raise SpikeError("INVALID_CAPTURE_METADATA", "Provide a small regular JSON sidecar.")
    try:
        capture = CaptureMetadata.model_validate(read_json(metadata))
    except ValidationError as e:
        raise SpikeError("INVALID_CAPTURE_METADATA", "Capture metadata violates the export contract.") from e
    if participant is not None and (capture.mode != "enrollment"
                                    or capture.participant_id != participant):
        raise SpikeError("CAPTURE_IDENTITY_MISMATCH", "Enrolment and sidecar identity must agree.")
    info = probe(video, enrollment=capture.mode == "enrollment")
    # Browser stop timing and integer UI seconds can differ slightly from container duration.
    if abs(info.duration - capture.duration_seconds) > 1.5:
        raise SpikeError("CAPTURE_DURATION_MISMATCH", "Sidecar duration does not match this video.")
    return {"status": "capture_pair_validated", "metadata": capture.model_dump(),
            "media": info.__dict__, "media_sha256": digest(video),
            "metadata_sha256": digest(metadata), "pairing": "operator_supplied",
            "pose_verification": "human_review_required",
            "warning": "Metadata has no video digest; duration cannot prove file pairing or consent."}
