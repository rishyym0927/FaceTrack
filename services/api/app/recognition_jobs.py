"""Recognition leases: roster-scoped ephemeral template access and guarded proposals."""

import json
import math
from collections import Counter
from itertools import groupby
from typing import Literal
from uuid import UUID, uuid4

from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from pydantic import Field, field_validator
from sqlalchemy import text

from . import biometrics as bio
from . import logs
from .attendance import FROZEN_ELIGIBILITY, FROZEN_ELIGIBILITY_JOINS
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


REASONS = Literal["recognized", "not_seen", "look_alike", "weak_match", "seen_too_briefly"]
REJECT_GATES = {"edge", "small", "landmarks", "brightness", "blur"}


class Diagnostic(Strict):
    student_id: UUID
    reason: REASONS
    observations: int = Field(ge=0, le=100000)
    best_similarity: float | None = Field(default=None, ge=-1, le=1)


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
    # Optional explanations from newer workers; older workers simply omit them.
    diagnostics: list[Diagnostic] = Field(default_factory=list, max_length=500)
    reject_reasons: dict[str, int] = Field(default_factory=dict, max_length=5)
    face_px_median: int = Field(default=0, ge=0, le=10000)
    sample_fps: float = Field(default=0, ge=0, le=100)
    _quality = field_validator("quality")(WorkerComplete.quality_bounds.__func__)
    _timings = field_validator("timings")(WorkerComplete.timings_finite.__func__)

    @field_validator("reject_reasons")
    @classmethod
    def known_gates(cls, v):
        if not set(v) <= REJECT_GATES or not all(0 <= n <= 100000 for n in v.values()):
            raise ValueError("Invalid rejection reasons.")
        return v

    @field_validator("proposals")
    @classmethod
    def unique(cls, v):
        if len({p.student_id for p in v}) != len(v):
            raise ValueError("Duplicate proposal.")
        return v


async def claim(conn, worker):
    if "recognition" not in worker["allowed_kinds"] or "recognition" not in worker.get(
        "ready_kinds", {"recognition"}
    ):
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


async def capture_context(conn, worker, job):
    """Capture, session, media and the enabled model/profile hashes in one statement, validated.

    Returns the capture/session facts and the media asset; raises when the input is revoked.
    """
    i = worker["institute_id"]
    found = await one(
        conn,
        f"""SELECT cap.session_id, cap.generation, s.status AS session_status, s.roster_hash,
        s.model_release_id, s.recognition_profile_id, {bio.MEDIA_SELECT},
        mr.manifest_hash, p.settings_hash
        FROM app.captures cap
        JOIN app.sessions s ON s.institute_id=cap.institute_id AND s.id=cap.session_id
        JOIN app.media_assets m ON m.institute_id=cap.institute_id AND m.id=cap.asset_id
        LEFT JOIN app.model_releases mr ON mr.institute_id=s.institute_id
          AND mr.id=s.model_release_id AND mr.status='enabled'
        LEFT JOIN app.recognition_profiles p ON p.institute_id=s.institute_id
          AND p.id=s.recognition_profile_id AND p.model_release_id=mr.id AND p.status='enabled'
        WHERE cap.institute_id=:i AND cap.id=:id""",
        {"i": i, "id": job["capture_id"]},
    )
    if not found:
        raise APIError(409, "JOB_INPUT_REVOKED", "Capture input is unavailable.")
    found, asset = bio.split_asset(found)
    if (
        "recognition" not in worker["allowed_kinds"]
        or not found["manifest_hash"]
        or found["manifest_hash"] not in worker["allowed_model_hashes"]
        or found["session_status"] in ("scheduled", "cancelled", "finalized")
        or asset["expires_at"] <= bio.now()
        or asset["status"] != "uploaded"
    ):
        raise APIError(409, "JOB_INPUT_REVOKED", "Capture input is unavailable.")
    return found, asset


async def eligible_identities(conn, institute, session_id):
    """Roster students whose frozen templates are still usable, decided in SQL.

    The same test the worker's input uses (active set of this epoch, consent in force, three to
    five templates), without reading or decrypting a single template.
    """
    rows = await many(
        conn,
        f"""SELECT r.student_id,r.template_set_id,r.template_epoch
            FROM app.session_roster r {FROZEN_ELIGIBILITY_JOINS}
            WHERE r.institute_id=:i AND r.session_id=:s AND {FROZEN_ELIGIBILITY}
            AND (SELECT count(*) FROM app.face_templates f
                 WHERE (f.institute_id,f.template_set_id)=(t.institute_id,t.id)) BETWEEN 3 AND 5""",
        {"i": institute, "s": session_id},
    )
    return {
        str(r["student_id"]): {
            "template_set_id": str(r["template_set_id"]),
            "template_epoch": r["template_epoch"],
        }
        for r in rows
    }


async def input_data(conn, worker, job, settings):
    i = worker["institute_id"]
    found, asset = await capture_context(conn, worker, job)
    s = {
        "id": found["session_id"],
        "model_release_id": found["model_release_id"],
        "roster_hash": found["roster_hash"],
    }
    cap = found
    cfg = found
    roster = await many(
        conn,
        f"""SELECT r.student_id,r.template_set_id,r.template_epoch,
                   f.ordinal,f.key_id,f.ciphertext,f.nonce
            FROM app.session_roster r {FROZEN_ELIGIBILITY_JOINS}
            JOIN app.face_templates f ON (f.institute_id,f.template_set_id)=(t.institute_id,t.id)
            WHERE r.institute_id=:i AND r.session_id=:s AND {FROZEN_ELIGIBILITY}
            ORDER BY r.student_id,f.ordinal""",
        {"i": i, "s": s["id"]},
    )
    people = []
    for _, group in groupby(roster, key=lambda row: row["student_id"]):
        templates = list(group)
        r = templates[0]
        vectors = []
        for f in templates:
            key = settings.template_keys.get(f["key_id"])
            if not key:
                raise APIError(
                    503, "TEMPLATE_KEY_UNAVAILABLE", "Template decryption is unavailable."
                )
            aad = f"{i}:{r['student_id']}:{r['template_set_id']}:{s['model_release_id']}:{f['ordinal']}".encode()
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
                    "template_set_id": str(r["template_set_id"]),
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
    from .worker_api import leased

    i = worker["institute_id"]
    # The roster is frozen when a session opens, so it can be read before any lock: it names the
    # students to lock. The session id comes with it (a lookup only when the roster is empty).
    roster = await many(
        conn,
        """SELECT r.* FROM app.session_roster r WHERE r.institute_id=:i AND r.session_id=
        (SELECT c.session_id FROM app.jobs j JOIN app.captures c
         ON c.institute_id=j.institute_id AND c.id=j.capture_id
         WHERE j.institute_id=:i AND j.id=:j) ORDER BY r.student_id""",
        {"i": i, "j": job_id},
    )
    if roster:
        session_id = roster[0]["session_id"]
    else:
        lookup = await one(
            conn,
            "SELECT c.session_id FROM app.jobs j JOIN app.captures c ON c.institute_id=j.institute_id AND c.id=j.capture_id WHERE j.institute_id=:i AND j.id=:j",
            {"i": i, "j": job_id},
        )
        if not lookup:
            raise APIError(404, "NOT_FOUND", "Capture job not found.")
        session_id = lookup["session_id"]
    # Same order as consent activation: student locks precede session/job row locks.
    # One statement instead of one round trip per student (125 ms each to the hosted database).
    # The roster is already ordered by student, which keeps the lock order the same as elsewhere.
    if roster:
        await conn.execute(
            text(
                """SELECT pg_advisory_xact_lock(hashtextextended('biometric:' || o.sid::text, 0))
                FROM (SELECT sid FROM unnest(CAST(:ids AS uuid[])) WITH ORDINALITY AS t(sid, n) ORDER BY n) o"""
            ),
            {"ids": [str(r["student_id"]) for r in roster]},
        )
    # Which students can still be matched is decided under the student locks (consent
    # withdrawals and approvals take them) but before the session lock, so the session stays
    # locked for as few round trips as possible. No template is read or decrypted here.
    allowed = await eligible_identities(conn, i, session_id)
    s = await one(
        conn,
        "SELECT * FROM app.sessions WHERE institute_id=:i AND id=:s FOR UPDATE",
        {"i": i, "s": session_id},
    )
    job = await leased(conn, worker, job_id, body.epoch, succeeded=True)
    digest = bio.digest(body.model_dump(exclude={"epoch"}))
    if job["state"] == "succeeded":
        if digest != job["result_hash"]:
            raise APIError(409, "RESULT_CONFLICT", "Different result already committed.")
        return {"state": "succeeded"}
    # Status, media and model are read after the session lock, so a cancel or publication that
    # got there first is seen.
    found, asset = await capture_context(conn, worker, job)
    if len(allowed) < 2:
        raise APIError(
            409, "INSUFFICIENT_TEMPLATES", "At least two eligible identities are required."
        )
    if any(
        (
            body.generation != found["generation"],
            body.source_sha256 != asset["sha256"],
            body.model_hash != found["manifest_hash"],
            body.profile_hash != found["settings_hash"],
            body.roster_hash != found["roster_hash"],
        )
    ):
        raise APIError(409, "INPUT_CHANGED", "Recognition input changed.")
    for p in body.proposals:
        ref = allowed.get(str(p.student_id))
        if (
            not ref
            or ref["template_set_id"] != str(p.template_set_id)
            or ref["template_epoch"] != p.template_epoch
        ):
            raise APIError(409, "INPUT_CHANGED", "Student consent or templates changed.")
    if body.proposals:
        # Evidence rows and the attendance marks that cite them: one statement, however many
        # students matched.
        await conn.execute(
            text(
                """WITH evidence AS (
                INSERT INTO app.recognition_evidence(institute_id,session_id,capture_id,student_id,template_set_id,template_epoch,accepted_hits,span_ms,scores_json,job_id)
                SELECT :i,:s,:c,v.student_id,v.template_set_id,v.epoch,v.hits,v.span,CAST(v.scores AS jsonb),:j
                FROM unnest(CAST(:students AS uuid[]),CAST(:sets AS uuid[]),CAST(:epochs AS int[]),CAST(:hits AS int[]),CAST(:spans AS float8[]),CAST(:scores AS text[]))
                AS v(student_id,template_set_id,epoch,hits,span,scores)
                RETURNING student_id,id)
                UPDATE app.attendance_records a SET status='proposed_present',source='ml',evidence_id=evidence.id,
                assessment_code='recognized',evidence_summary=CAST(m.summary AS jsonb),version=a.version+1
                FROM evidence JOIN unnest(CAST(:students AS uuid[]),CAST(:summaries AS text[])) AS m(student_id,summary)
                ON m.student_id=evidence.student_id
                WHERE a.institute_id=:i AND a.session_id=:s AND a.student_id=evidence.student_id AND NOT a.manual_lock"""
            ),
            {
                "i": i,
                "s": s["id"],
                "c": job["capture_id"],
                "j": job_id,
                "students": [str(p.student_id) for p in body.proposals],
                "sets": [str(p.template_set_id) for p in body.proposals],
                "epochs": [p.template_epoch for p in body.proposals],
                "hits": [p.hits for p in body.proposals],
                "spans": [p.span_ms for p in body.proposals],
                "scores": [json.dumps({"median_similarity": p.similarity}) for p in body.proposals],
                "summaries": [
                    json.dumps(
                        {"hits": p.hits, "span_ms": p.span_ms, "median_similarity": p.similarity}
                    )
                    for p in body.proposals
                ],
            },
        )
    proposed = {str(p.student_id) for p in body.proposals}
    why = {str(d.student_id): d for d in body.diagnostics}
    usable = max(0, body.quality.get("detections", 0) - body.quality.get("quality_rejects", 0))
    sufficient_capture = body.quality.get("sampled_frames", 0) >= 2 and usable >= 2
    rows = []
    for r in roster:
        student_id = str(r["student_id"])
        eligible = student_id in allowed
        if student_id in proposed or (not eligible and not sufficient_capture):
            continue
        rows.append(
            (
                student_id,
                "template_ineligible"
                if not eligible
                else "not_recognized"
                if sufficient_capture
                else "limited_capture",
                json.dumps(
                    {
                        "usable_observations": usable,
                        **(
                            {
                                "reason": why[student_id].reason,
                                "observations": why[student_id].observations,
                                "best_similarity": why[student_id].best_similarity,
                            }
                            if student_id in why
                            else {}
                        ),
                    }
                ),
            )
        )
    if rows:
        await conn.execute(
            text(
                """UPDATE app.attendance_records a SET status=:status,source=:source,
                assessment_code=v.code,evidence_summary=CAST(v.summary AS jsonb),version=a.version+1
                FROM unnest(CAST(:students AS uuid[]),CAST(:codes AS text[]),CAST(:summaries AS text[])) AS v(student_id,code,summary)
                WHERE a.institute_id=:i AND a.session_id=:s AND a.student_id=v.student_id AND NOT a.manual_lock
                AND a.status<>'proposed_present'
                AND (:sufficient OR a.status<>'proposed_absent')"""
            ),
            {
                "status": "proposed_absent" if sufficient_capture else "unassessed",
                "source": "ml" if sufficient_capture else "none",
                "sufficient": sufficient_capture,
                "i": i,
                "s": s["id"],
                "students": [r[0] for r in rows],
                "codes": [r[1] for r in rows],
                "summaries": [r[2] for r in rows],
            },
        )
    quality = {
        "counts": body.quality,
        "timings": body.timings,
        "unknown_observations": body.unknown_observations,
        "processed_sha256": body.processed_sha256,
        "reject_reasons": body.reject_reasons,
        "face_px_median": body.face_px_median,
        "sample_fps": body.sample_fps,
    }
    # Capture, job, session and media transitions plus the audit row: one statement.
    await conn.execute(
        text(
            """WITH capture AS (UPDATE app.captures SET status='review_required',quality_json=CAST(:q AS jsonb),version=version+1
                WHERE institute_id=:i AND id=:capture),
            finished AS (UPDATE app.jobs SET state='succeeded',stage='review_required',result_hash=:h
                WHERE institute_id=:i AND id=:job),
            opened AS (UPDATE app.sessions SET status=CASE WHEN status IN ('closed','no_data') THEN 'review_required' ELSE status END,version=version+1
                WHERE institute_id=:i AND id=:session),
            media AS (UPDATE app.media_assets SET status='delete_pending' WHERE institute_id=:i AND id=:asset)
            INSERT INTO app.audit_events(institute_id,actor_id,action,resource_type,resource_id,request_id,summary)
            VALUES(:i,NULL,'capture.processed','job',:job,:request,CAST(:summary AS jsonb))"""
        ),
        {
            "q": json.dumps(quality),
            "i": i,
            "capture": job["capture_id"],
            "h": digest,
            "job": job_id,
            "session": s["id"],
            "asset": asset["id"],
            "request": str(uuid4()),
            "summary": json.dumps({"worker_id": str(worker["id"])}),
        },
    )
    logs.event(
        "recognition_complete",
        session_id=s["id"],
        job_id=job_id,
        roster=len(roster),
        recognised=len(body.proposals),
        unknown_observations=body.unknown_observations,
        quality=body.quality,
        reject_reasons=body.reject_reasons,
        face_px_median=body.face_px_median,
        sample_fps=body.sample_fps,
        timings=body.timings,
        reasons=dict(Counter(d.reason for d in body.diagnostics)),
    )
    return {"state": "succeeded"}
