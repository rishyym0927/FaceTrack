"""Versioned research-only ML candidates; never imported by the product worker."""

from .pipeline import (
    CandidateConfig,
    CandidateQualityGate,
    DetectorFrame,
    FivePointYawResearch,
    MultiScaleScrfd,
    safe_align,
)

__all__ = [
    "CandidateConfig",
    "CandidateQualityGate",
    "DetectorFrame",
    "FivePointYawResearch",
    "MultiScaleScrfd",
    "safe_align",
]
