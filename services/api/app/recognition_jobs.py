"""Recognition leases: roster-scoped ephemeral template access and guarded proposals."""

import json
import math
from uuid import UUID

from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from pydantic import Field, field_validator
from sqlalchemy import text

from . import biometrics as bio
from .attendance import eligible
from .biometric_types import Epoch, WorkerComplete
from .db import many, one
from .errors import APIError
from .schemas import Strict


class Proposal(Strict):
    student_id: UUID
    template_set_id: UUID
    template_epoch: int = Field(ge=0)
    hits: int = Field(ge=2, le=100000)
    span_ms: float = Field(ge=500, le=60000, allow_inf_nan=False)
    similarity: float = Field(ge=-1, le=1, allow_inf_nan=False)


class RecognitionComplete(Epoch):
    generation: int = Field(gt=0)
    source_sha256: str = Field(pattern=r"^[a-f0-9]{64}$")
    processed_sha256: str = Field(pattern=r"^[a-f0-9]{64}$")
    model_hash: str = Field(pattern=r"^[a-f0-9]{64}$")
    profile_hash: str = Field(pattern=r"^[a-f0-9]{64}$")
    roster_hash: str = Field(pattern=r"^[a-f0-9]{64}$")
    proposals: list[Proposal] = Field(max_length=500)
    unknown_observations: int = Field(ge=0, le=100000)
    quality: dict[str, int] = Field(max_length=10)
    timings: dict[str, float] = Field(max_length=10)
    _quality = field_validator("quality")(WorkerComplete.quality_bounds.__func__)
    _timings = field_validator("timings")(WorkerComplete.timings_finite.__func__)

    @field_validator("proposals")
    @classmethod
    def unique(cls, v):
        if len({p.student_id for p in v}) != len(v):
            raise ValueError("Duplicate proposal.")
        return v


async def claim(conn, worker):
    if "recognition" not in worker["allowed_kinds"]:
        from .documents import claim as document_claim

        return await document_claim(conn, worker)
    job = await one(
        conn,
        """SELECT j.id FROM app.jobs j JOIN app.captures c ON c.institute_id=j.institute_id AND c.id=j.capture_id
    JOIN app.sessions s ON s.institute_id=c.institute_id AND s.id=c.session_id
    JOIN app.model_releases m ON m.institute_id=s.institute_id AND m.id=s.model_release_id
    WHERE j.institute_id=:i AND j.kind='recognition' AND j.state IN ('queued','retry_wait') AND j.available_at<=now() AND j.attempts<3
    AND s.status IN ('open','closed','review_required','no_data') AND m.status='enabled' AND CAST(:h AS jsonb) ? m.manifest_hash
    ORDER BY j.created_at FOR UPDATE OF j SKIP LOCKED LIMIT 1""",
        {"i": worker["institute_id"], "h": json.dumps(worker["allowed_model_hashes"])},
    )
    if not job:
        from .documents import claim as document_claim

        return await document_claim(conn, worker)
    return dict(
        await one(
            conn,
            "UPDATE app.jobs SET state='leased',stage='leased',attempts=attempts+1,lease_epoch=lease_epoch+1,lease_owner=:w,lease_expires_at=now()+interval '120 seconds' WHERE institute_id=:i AND id=:id RETURNING id,lease_epoch,generation",
            {"i": worker["institute_id"], "w": worker["id"], "id": job["id"]},
        )
    )


async def input_data(conn, worker, job, settings):
    i = worker["institute_id"]
    cap = await one(
        conn,
        "SELECT * FROM app.captures WHERE institute_id=:i AND id=:id",
        {"i": i, "id": job["capture_id"]},
    )
    s = await one(
        conn,
        "SELECT * FROM app.sessions WHERE institute_id=:i AND id=:id",
        {"i": i, "id": cap["session_id"]},
    )
    asset = dict(
        await one(
            conn,
            "SELECT * FROM app.media_assets WHERE institute_id=:i AND id=:id",
            {"i": i, "id": cap["asset_id"]},
        )
    )
    cfg = await one(
        conn,
        """SELECT m.manifest_hash,p.settings_hash FROM app.model_releases m JOIN app.recognition_profiles p ON p.institute_id=m.institute_id AND p.model_release_id=m.id
    WHERE m.institute_id=:i AND m.id=:m AND p.id=:p AND m.status='enabled' AND p.status='enabled'""",
        {"i": i, "m": s["model_release_id"], "p": s["recognition_profile_id"]},
    )
    if (
        "recognition" not in worker["allowed_kinds"]
        or not cfg
        or cfg["manifest_hash"] not in worker["allowed_model_hashes"]
        or s["status"] in ("scheduled", "cancelled", "finalized")
        or asset["expires_at"] <= bio.now()
        or asset["status"] != "uploaded"
    ):
        raise APIError(409, "JOB_INPUT_REVOKED", "Capture input is unavailable.")
    roster = await many(
        conn,
        "SELECT * FROM app.session_roster WHERE institute_id=:i AND session_id=:s AND recognition_eligible ORDER BY student_id",
        {"i": i, "s": s["id"]},
    )
    people = []
    for r in roster:
        t = await eligible(conn, i, r["student_id"], r["template_set_id"], r["template_epoch"])
        if not t:
            continue
        vectors = []
        for f in await many(
            conn,
            "SELECT * FROM app.face_templates WHERE institute_id=:i AND template_set_id=:t ORDER BY ordinal",
            {"i": i, "t": t["id"]},
        ):
            key = settings.template_keys.get(f["key_id"])
            if not key:
                raise APIError(
                    503, "TEMPLATE_KEY_UNAVAILABLE", "Template decryption is unavailable."
                )
            aad = f"{i}:{r['student_id']}:{t['id']}:{s['model_release_id']}:{f['ordinal']}".encode()
            vector = json.loads(
                AESGCM(bytes.fromhex(key.get_secret_value())).decrypt(
                    bytes(f["nonce"]), bytes(f["ciphertext"]), aad
                )
            )
            if len(vector) != 512 or not all(math.isfinite(x) for x in vector):
                raise APIError(409, "INVALID_TEMPLATE", "Template integrity failed.")
            vectors.append(vector)
        if 3 <= len(vectors) <= 5:
            people.append(
                {
                    "student_id": str(r["student_id"]),
                    "template_set_id": str(t["id"]),
                    "template_epoch": r["template_epoch"],
                    "vectors": vectors,
                }
            )
    if len(people) < 2:
        raise APIError(
            409, "INSUFFICIENT_TEMPLATES", "At least two eligible identities are required."
        )
    return {
        "kind": "recognition",
        "generation": cap["generation"],
        "source_sha256": asset["sha256"],
        "byte_size": asset["byte_size"],
        "model_hash": cfg["manifest_hash"],
        "profile_hash": cfg["settings_hash"],
        "roster_hash": s["roster_hash"],
        "roster": people,
    }, asset


async def complete(conn, worker, job_id, body, settings):
    from .worker_api import audit_worker, leased

    i = worker["institute_id"]
    lookup = await one(
        conn,
        "SELECT c.session_id FROM app.jobs j JOIN app.captures c ON c.institute_id=j.institute_id AND c.id=j.capture_id WHERE j.institute_id=:i AND j.id=:j",
        {"i": i, "j": job_id},
    )
    if not lookup:
        raise APIError(404, "NOT_FOUND", "Capture job not found.")
    # Same order as consent activation: student locks precede session/job row locks.
    roster = await many(
        conn,
        "SELECT * FROM app.session_roster WHERE institute_id=:i AND session_id=:s ORDER BY student_id",
        {"i": i, "s": lookup["session_id"]},
    )
    for r in roster:
        await bio.lock_student(conn, r["student_id"])
    s = await one(
        conn,
        "SELECT * FROM app.sessions WHERE institute_id=:i AND id=:s FOR UPDATE",
        {"i": i, "s": lookup["session_id"]},
    )
    job = await leased(conn, worker, job_id, body.epoch, succeeded=True)
    digest = bio.digest(body.model_dump(exclude={"epoch"}))
    if job["state"] == "succeeded":
        if digest != job["result_hash"]:
            raise APIError(409, "RESULT_CONFLICT", "Different result already committed.")
        return {"state": "succeeded"}
    # Obtain only metadata here; input_data rechecks consent and validates encrypted templates.
    data, asset = await input_data(conn, worker, job, settings)
    if any(
        (
            body.generation != data["generation"],
            body.source_sha256 != data["source_sha256"],
            body.model_hash != data["model_hash"],
            body.profile_hash != data["profile_hash"],
            body.roster_hash != data["roster_hash"],
        )
    ):
        raise APIError(409, "INPUT_CHANGED", "Recognition input changed.")
    allowed = {p["student_id"]: p for p in data["roster"]}
    for p in body.proposals:
        ref = allowed.get(str(p.student_id))
        if (
            not ref
            or ref["template_set_id"] != str(p.template_set_id)
            or ref["template_epoch"] != p.template_epoch
        ):
            raise APIError(409, "INPUT_CHANGED", "Student consent or templates changed.")
        ev = await one(
            conn,
            """INSERT INTO app.recognition_evidence(institute_id,session_id,capture_id,student_id,template_set_id,template_epoch,accepted_hits,span_ms,scores_json,job_id)
        VALUES(:i,:s,:c,:student,:t,:epoch,:hits,:span,CAST(:scores AS jsonb),:j) RETURNING id""",
            {
                "i": i,
                "s": s["id"],
                "c": job["capture_id"],
                "student": p.student_id,
                "t": p.template_set_id,
                "epoch": p.template_epoch,
                "hits": p.hits,
                "span": p.span_ms,
                "scores": json.dumps({"median_similarity": p.similarity}),
                "j": job_id,
            },
        )
        await conn.execute(
            text(
                "UPDATE app.attendance_records SET status='proposed_present',source='ml',evidence_id=:e,assessment_code='recognized',evidence_summary=CAST(:summary AS jsonb),version=version+1 WHERE institute_id=:i AND session_id=:s AND student_id=:student AND NOT manual_lock"
            ),
            {
                "e": ev["id"],
                "summary": json.dumps(
                    {"hits": p.hits, "span_ms": p.span_ms, "median_similarity": p.similarity}
                ),
                "i": i,
                "s": s["id"],
                "student": p.student_id,
            },
        )
    proposed = {str(p.student_id) for p in body.proposals}
    usable = max(0, body.quality.get("detections", 0) - body.quality.get("quality_rejects", 0))
    sufficient_capture = body.quality.get("sampled_frames", 0) >= 2 and usable >= 2
    for r in roster:
        if not r["recognition_eligible"] or str(r["student_id"]) in proposed:
            continue
        await conn.execute(
            text(
                """UPDATE app.attendance_records SET status=:status,source=:source,
                assessment_code=:code,evidence_summary=CAST(:summary AS jsonb),version=version+1
                WHERE institute_id=:i AND session_id=:s AND student_id=:student AND NOT manual_lock
                AND status<>'proposed_present'"""
            ),
            {
                "status": "proposed_absent" if sufficient_capture else "unassessed",
                "source": "ml" if sufficient_capture else "none",
                "code": "not_recognized" if sufficient_capture else "limited_capture",
                "summary": json.dumps({"usable_observations": usable}),
                "i": i,
                "s": s["id"],
                "student": r["student_id"],
            },
        )
    quality = {
        "counts": body.quality,
        "timings": body.timings,
        "unknown_observations": body.unknown_observations,
        "processed_sha256": body.processed_sha256,
    }
    await conn.execute(
        text(
            "UPDATE app.captures SET status='review_required',quality_json=CAST(:q AS jsonb),version=version+1 WHERE institute_id=:i AND id=:id"
        ),
        {"q": json.dumps(quality), "i": i, "id": job["capture_id"]},
    )
    await conn.execute(
        text(
            "UPDATE app.jobs SET state='succeeded',stage='review_required',result_hash=:h WHERE institute_id=:i AND id=:id"
        ),
        {"h": digest, "i": i, "id": job_id},
    )
    await conn.execute(
        text(
            "UPDATE app.sessions SET status=CASE WHEN status IN ('closed','no_data') THEN 'review_required' ELSE status END,version=version+1 WHERE institute_id=:i AND id=:id"
        ),
        {"i": i, "id": s["id"]},
    )
    await conn.execute(
        text(
            "UPDATE app.media_assets SET status='delete_pending' WHERE institute_id=:i AND id=:id"
        ),
        {"i": i, "id": asset["id"]},
    )
    await audit_worker(conn, worker, job_id, "capture.processed")
    return {"state": "succeeded"}
