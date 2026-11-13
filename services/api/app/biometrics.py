"""Tenant-scoped enrolment orchestration; inference stays outside HTTP handlers."""

import hashlib
import json
import secrets
from datetime import datetime, timezone
from uuid import uuid4

from sqlalchemy import text

from .db import many, one
from .errors import APIError
from .security import audit, check_cursor, idempotent, page, remember, roles, teacher_access

NOTICE_VERSION = "academic-demo-v1"
NOTICE = (
    "This voluntary academic demonstration records a short face video and derives encrypted face templates. "
    "Private video and encrypted templates are stored in the institute development Supabase project; "
    "processing runs on the operator Mac. Only authorized related faculty can review your video. "
    "Video is removed after review or within 24 hours, with overdue cleanup reconciled when the Mac resumes. "
    "You may withdraw consent and use manual attendance without penalty. Templates are blocked immediately "
    "on withdrawal and scheduled for deletion within 24 hours. This is not certified liveness or validated "
    "institute-wide recognition. Do not enrol without understanding and agreeing to this notice."
)
NOTICE_HASH = hashlib.sha256(NOTICE.encode()).hexdigest()
UNFINISHED = ("awaiting_upload", "queued", "processing", "review_required")
ATTEMPT_FIELDS = "a.id,a.student_id,a.asset_id,a.status,a.version,a.pose_order,a.quality_json,a.reason,a.created_at,m.expires_at,m.reservation_expires_at"
CURRENT_RECOGNITION_PROFILE = """SELECT m.id AS model,p.id AS profile
    FROM app.model_releases m JOIN app.recognition_profiles p
      ON p.institute_id=m.institute_id AND p.model_release_id=m.id
    WHERE m.institute_id=:i AND m.status='enabled' AND p.status='enabled'
    ORDER BY p.created_at DESC,p.id DESC LIMIT 1"""


def now():
    return datetime.now(timezone.utc)


def digest(value):
    return hashlib.sha256(
        json.dumps(
            value, sort_keys=True, separators=(",", ":"), default=str, allow_nan=False
        ).encode()
    ).hexdigest()


async def lock_student(conn, student):
    await conn.execute(
        text("SELECT pg_advisory_xact_lock(hashtextextended(:v,0))"),
        {"v": "biometric:" + str(student)},
    )


async def student(conn, actor, institute):
    permissions = await roles(conn, actor, institute)
    row = await one(
        conn,
        "SELECT * FROM app.students WHERE institute_id=:i AND auth_user_id=:a AND status='approved'",
        {"i": institute, "a": actor},
    )
    if "student" not in permissions or not row:
        raise APIError(403, "STUDENT_REQUIRED", "An approved linked student identity is required.")
    return row


async def review_access(conn, actor, institute, student_id):
    permissions = await roles(conn, actor, institute)
    if "admin" in permissions:
        return
    if "teacher" in permissions and await one(
        conn,
        """SELECT e.id FROM app.course_enrollments e
        JOIN app.offering_teachers ot ON ot.institute_id=e.institute_id AND ot.offering_id=e.offering_id
        JOIN app.teachers t ON t.institute_id=ot.institute_id AND t.id=ot.teacher_id
        WHERE e.institute_id=:i AND e.student_id=:s AND e.status='active'
        AND e.effective_from<=now() AND (e.effective_until IS NULL OR e.effective_until>now())
        AND ot.status='active' AND t.auth_user_id=:a AND t.status='approved'""",
        {"i": institute, "s": student_id, "a": actor},
    ):
        return
    raise APIError(404, "NOT_FOUND", "Enrolment not found.")


async def get_attempt(conn, institute, identifier):
    row = await one(
        conn,
        "SELECT * FROM app.enrollment_attempts WHERE institute_id=:i AND id=:id",
        {"i": institute, "id": identifier},
    )
    if not row:
        raise APIError(404, "NOT_FOUND", "Enrolment not found.")
    return row


async def attempt_view(conn, institute, identifier):
    row = await one(
        conn,
        f"SELECT {ATTEMPT_FIELDS} FROM app.enrollment_attempts a JOIN app.media_assets m ON m.institute_id=a.institute_id AND m.id=a.asset_id WHERE a.institute_id=:i AND a.id=:id",
        {"i": institute, "id": identifier},
    )
    result = dict(row)
    result["job"] = None
    job = await one(
        conn,
        "SELECT id,state,stage,error_code FROM app.jobs WHERE institute_id=:i AND enrollment_attempt_id=:a ORDER BY created_at DESC LIMIT 1",
        {"i": institute, "a": identifier},
    )
    if job:
        result["job"] = dict(job)
    return result


async def own_state(conn, actor, institute):
    s = await student(conn, actor, institute)
    attempt = await one(
        conn,
        "SELECT id FROM app.enrollment_attempts WHERE institute_id=:i AND student_id=:s ORDER BY created_at DESC,id DESC LIMIT 1",
        {"i": institute, "s": s["id"]},
    )
    consent = await one(
        conn,
        "SELECT id,notice_version FROM app.consents WHERE institute_id=:i AND student_id=:s AND withdrawn_at IS NULL ORDER BY created_at DESC LIMIT 1",
        {"i": institute, "s": s["id"]},
    )
    active = await many(
        conn,
        "SELECT id,activated_at FROM app.template_sets WHERE institute_id=:i AND student_id=:s AND status='active'",
        {"i": institute, "s": s["id"]},
    )
    return {
        "attempt": await attempt_view(conn, institute, attempt["id"]) if attempt else None,
        "consent": dict(consent) if consent else None,
        "active_sets": [dict(x) for x in active],
    }


async def accept(conn, actor, institute, body, key, request_id):
    s = await student(conn, actor, institute)
    await lock_student(conn, s["id"])
    if body.notice_version != NOTICE_VERSION or body.notice_hash != NOTICE_HASH:
        raise APIError(409, "NOTICE_CHANGED", "Read the current notice before accepting.")
    route = "/v1/consents"
    cached, fingerprint = await idempotent(conn, actor, institute, route, key, body.model_dump())
    if cached:
        current = await one(
            conn,
            "SELECT withdrawn_at FROM app.consents WHERE id=:id AND institute_id=:i",
            {"id": cached["id"], "i": institute},
        )
        if not current or current["withdrawn_at"]:
            raise APIError(409, "CONSENT_WITHDRAWN", "Accept the notice again with a new action.")
        return cached
    row = await one(
        conn,
        """INSERT INTO app.consents(institute_id,student_id,notice_version,notice_hash)
        VALUES(:i,:s,:v,:h) RETURNING id,notice_version""",
        {"i": institute, "s": s["id"], "v": NOTICE_VERSION, "h": NOTICE_HASH},
    )
    result = dict(row)
    await remember(conn, actor, institute, route, key, fingerprint, result)
    await audit(conn, actor, institute, "consent.accept", "consent", row["id"], request_id)
    return result


async def revoke_sets(conn, institute, student_id, *, consent_id=None):
    params = {"i": institute, "s": student_id, "c": consent_id}
    condition = "AND a.consent_id=:c" if consent_id else ""
    await conn.execute(
        text(f"""UPDATE app.template_sets t SET status='revoked',revoked_at=now(),version=t.version+1
        FROM app.enrollment_attempts a WHERE t.institute_id=:i AND t.student_id=:s
        AND a.institute_id=t.institute_id AND a.id=t.attempt_id AND t.status IN ('active','review_required') {condition}"""),
        params,
    )
    await conn.execute(
        text(
            "DELETE FROM app.face_templates f USING app.template_sets t WHERE f.institute_id=:i AND f.template_set_id=t.id AND t.institute_id=f.institute_id AND t.student_id=:s AND t.status='revoked'"
        ),
        params,
    )


async def withdraw(conn, actor, institute, identifier, request_id):
    s = await student(conn, actor, institute)
    await lock_student(conn, s["id"])
    row = await one(
        conn,
        "UPDATE app.consents SET withdrawn_at=coalesce(withdrawn_at,now()),version=version+1 WHERE institute_id=:i AND id=:id AND student_id=:s RETURNING id",
        {"i": institute, "id": identifier, "s": s["id"]},
    )
    if not row:
        raise APIError(404, "NOT_FOUND", "Consent not found.")
    await conn.execute(
        text(
            "UPDATE app.consents SET withdrawn_at=coalesce(withdrawn_at,now()) WHERE institute_id=:i AND student_id=:s"
        ),
        {"i": institute, "s": s["id"]},
    )
    await revoke_sets(conn, institute, s["id"])
    await conn.execute(
        text("""UPDATE app.enrollment_attempts SET status='cancelled',version=version+1
        WHERE institute_id=:i AND student_id=:s AND status IN ('awaiting_upload','queued','processing','review_required','active')"""),
        {"i": institute, "s": s["id"], "c": identifier},
    )
    await conn.execute(
        text("""UPDATE app.jobs j SET state='cancelled',stage='cancelled' FROM app.enrollment_attempts a
        WHERE j.institute_id=:i AND a.institute_id=j.institute_id AND a.id=j.enrollment_attempt_id AND a.student_id=:s
        AND j.state NOT IN ('succeeded','failed','cancelled')"""),
        {"i": institute, "s": s["id"]},
    )
    await conn.execute(
        text("""UPDATE app.media_assets m SET status='delete_pending' FROM app.enrollment_attempts a
        WHERE m.institute_id=:i AND a.institute_id=m.institute_id AND a.asset_id=m.id AND a.student_id=:s AND m.status<>'deleted'"""),
        {"i": institute, "s": s["id"]},
    )
    await conn.execute(text("SELECT app.bump_template_epoch(:s)"), {"s": s["id"]})
    await audit(conn, actor, institute, "consent.withdraw", "consent", identifier, request_id)
    return {"status": "withdrawn"}


async def create(conn, actor, institute, body, key, settings, request_id):
    s = await student(conn, actor, institute)
    await lock_student(conn, s["id"])
    route = "/v1/biometric-enrollments"
    cached, fingerprint = await idempotent(conn, actor, institute, route, key, body.model_dump())
    if cached:
        return await attempt_view(conn, institute, cached["id"])
    consent = await one(
        conn,
        "SELECT id FROM app.consents WHERE institute_id=:i AND id=:c AND student_id=:s AND withdrawn_at IS NULL AND notice_hash=:h",
        {"i": institute, "c": body.consent_id, "s": s["id"], "h": NOTICE_HASH},
    )
    if not consent:
        raise APIError(409, "CONSENT_REQUIRED", "Accept the current notice first.")
    model = await one(
        conn,
        """SELECT p.id AS profile_id,p.model_release_id FROM app.recognition_profiles p
        JOIN app.model_releases m ON m.institute_id=p.institute_id AND m.id=p.model_release_id
        WHERE p.institute_id=:i AND p.status='enabled' AND m.status='enabled' AND m.license_status='academic_local_only'
        ORDER BY p.created_at DESC LIMIT 1""",
        {"i": institute},
    )
    if not model or not settings.template_keys:
        raise APIError(
            503,
            "ENROLLMENT_NOT_READY",
            "Face enrolment processing is not configured.",
            retryable=True,
        )
    asset, attempt = uuid4(), uuid4()
    poses = ["up", "down", "left", "right"]
    secrets.SystemRandom().shuffle(poses)
    poses.insert(0, "front")
    await conn.execute(
        text("""INSERT INTO app.media_assets(id,institute_id,owner_user_id,purpose,bucket,object_key,mime_type,expected_bytes)
        VALUES(:id,:i,:a,'enrollment',:b,:k,:mime,:n)"""),
        {
            "id": asset,
            "i": institute,
            "a": actor,
            "b": settings.enrollment_bucket,
            "k": f"{institute}/{asset}/{secrets.token_hex(16)}",
            "mime": body.mime_type,
            "n": body.expected_bytes,
        },
    )
    await conn.execute(
        text("""INSERT INTO app.enrollment_attempts(id,institute_id,student_id,consent_id,asset_id,model_release_id,recognition_profile_id,pose_order,challenge_hash)
        VALUES(:id,:i,:s,:c,:asset,:model,:profile,CAST(:poses AS jsonb),:hash)"""),
        {
            "id": attempt,
            "i": institute,
            "s": s["id"],
            "c": body.consent_id,
            "asset": asset,
            "model": model["model_release_id"],
            "profile": model["profile_id"],
            "poses": json.dumps(poses),
            "hash": digest({"poses": poses, "attempt": attempt}),
        },
    )
    await remember(conn, actor, institute, route, key, fingerprint, {"id": str(attempt)})
    await audit(
        conn, actor, institute, "enrollment.create", "enrollment_attempt", attempt, request_id
    )
    return await attempt_view(conn, institute, attempt)


async def owned_asset(conn, actor, institute, identifier, *, grant=False):
    s = await student(conn, actor, institute)
    a = await get_attempt(conn, institute, identifier)
    if a["student_id"] != s["id"]:
        raise APIError(404, "NOT_FOUND", "Enrolment not found.")
    asset = await one(
        conn,
        "SELECT * FROM app.media_assets WHERE institute_id=:i AND id=:id",
        {"i": institute, "id": a["asset_id"]},
    )
    if grant:
        consent = await one(
            conn,
            "SELECT withdrawn_at FROM app.consents WHERE institute_id=:i AND id=:c",
            {"i": institute, "c": a["consent_id"]},
        )
        if (
            a["status"] != "awaiting_upload"
            or asset["reservation_expires_at"] <= now()
            or consent["withdrawn_at"]
        ):
            raise APIError(409, "UPLOAD_EXPIRED", "This upload is closed. Start a new recording.")
        await conn.execute(
            text(
                "UPDATE app.media_assets SET grant_expires_at=now()+interval '2 hours' WHERE institute_id=:i AND id=:id"
            ),
            {"i": institute, "id": asset["id"]},
        )
    return a, dict(asset)


async def upload_complete(conn, actor, institute, identifier, body, info, key, request_id):
    s = await student(conn, actor, institute)
    await lock_student(conn, s["id"])
    a, asset = await owned_asset(conn, actor, institute, identifier)
    route = f"/v1/biometric-enrollments/{identifier}/upload-complete"
    cached, fingerprint = await idempotent(conn, actor, institute, route, key, body.model_dump())
    if cached:
        return cached
    if body.asset_id != asset["id"]:
        raise APIError(404, "NOT_FOUND", "Video not found.")
    await owned_asset(conn, actor, institute, identifier, grant=True)
    if (
        body.byte_size != asset["expected_bytes"]
        or info["size"] != body.byte_size
        or info["mime_type"].split(";")[0] != asset["mime_type"]
    ):
        raise APIError(409, "MEDIA_MISMATCH", "Video metadata differs from its reservation.")
    await conn.execute(
        text(
            "UPDATE app.media_assets SET status='uploaded',byte_size=:n,sha256=:h WHERE institute_id=:i AND id=:id"
        ),
        {"n": body.byte_size, "h": body.sha256, "i": institute, "id": asset["id"]},
    )
    await conn.execute(
        text(
            "UPDATE app.enrollment_attempts SET status='queued',version=version+1 WHERE institute_id=:i AND id=:id"
        ),
        {"i": institute, "id": identifier},
    )
    job = uuid4()
    await conn.execute(
        text(
            "INSERT INTO app.jobs(id,institute_id,kind,enrollment_attempt_id,dedup_key,generation) VALUES(:id,:i,'enrollment',:a,:key,:g)"
        ),
        {
            "id": job,
            "i": institute,
            "a": identifier,
            "key": f"enroll:{identifier}:{a['generation']}",
            "g": a["generation"],
        },
    )
    result = {
        "job_id": str(job),
        "resource_id": str(identifier),
        "state": "queued",
        "status_url": f"/v1/jobs/{job}",
    }
    await remember(conn, actor, institute, route, key, fingerprint, result, 202)
    await audit(conn, actor, institute, "enrollment.queue", "job", job, request_id)
    return result


async def cancel(conn, actor, institute, identifier, version, request_id):
    s = await student(conn, actor, institute)
    await lock_student(conn, s["id"])
    a, asset = await owned_asset(conn, actor, institute, identifier)
    if a["version"] != version or a["status"] not in UNFINISHED:
        raise APIError(409, "VERSION_CONFLICT", "Refresh this enrolment before cancelling.")
    await conn.execute(
        text(
            "UPDATE app.enrollment_attempts SET status='cancelled',version=version+1 WHERE institute_id=:i AND id=:id"
        ),
        {"i": institute, "id": identifier},
    )
    await conn.execute(
        text(
            "UPDATE app.jobs SET state='cancelled',stage='cancelled' WHERE institute_id=:i AND enrollment_attempt_id=:id AND state NOT IN ('succeeded','failed','cancelled')"
        ),
        {"i": institute, "id": identifier},
    )
    await conn.execute(
        text(
            "UPDATE app.media_assets SET status='delete_pending' WHERE institute_id=:i AND id=:id AND status<>'deleted'"
        ),
        {"i": institute, "id": asset["id"]},
    )
    # Only the cancelled attempt's candidate is revoked; an existing active set survives.
    await conn.execute(
        text(
            "UPDATE app.template_sets SET status='revoked',revoked_at=now() WHERE institute_id=:i AND attempt_id=:a AND status='review_required'"
        ),
        {"i": institute, "a": identifier},
    )
    await conn.execute(
        text(
            "DELETE FROM app.face_templates f USING app.template_sets t WHERE f.institute_id=:i AND t.institute_id=f.institute_id AND t.id=f.template_set_id AND t.attempt_id=:a"
        ),
        {"i": institute, "a": identifier},
    )
    await audit(
        conn, actor, institute, "enrollment.cancel", "enrollment_attempt", identifier, request_id
    )
    return {"status": "cancelled"}


async def review_list(conn, actor, institute, offering, cursor, limit):
    await teacher_access(conn, actor, institute, offering)
    await check_cursor(
        conn,
        cursor,
        """SELECT 1 FROM app.enrollment_attempts a
        JOIN app.course_enrollments e ON e.institute_id=a.institute_id AND e.student_id=a.student_id
        WHERE a.institute_id=:i AND a.id=CAST(:cur AS uuid) AND a.status='review_required'
        AND e.offering_id=:o AND e.status='active' AND e.effective_from<=now()
        AND (e.effective_until IS NULL OR e.effective_until>now())""",
        {"i": institute, "o": offering},
    )
    rows = await many(
        conn,
        f"""SELECT {ATTEMPT_FIELDS},s.official_name,s.enrollment_number FROM app.enrollment_attempts a
        JOIN app.media_assets m ON m.institute_id=a.institute_id AND m.id=a.asset_id
        JOIN app.students s ON s.institute_id=a.institute_id AND s.id=a.student_id
        JOIN app.course_enrollments e ON e.institute_id=a.institute_id AND e.student_id=a.student_id
        WHERE a.institute_id=:i AND e.offering_id=:o AND e.status='active' AND e.effective_from<=now()
        AND (e.effective_until IS NULL OR e.effective_until>now()) AND a.status='review_required'
        AND (CAST(:c AS uuid) IS NULL OR (a.created_at,a.id)>(SELECT created_at,id
          FROM app.enrollment_attempts WHERE institute_id=:i AND id=CAST(:c AS uuid)))
        ORDER BY a.created_at,a.id LIMIT :n""",
        {"i": institute, "o": offering, "c": str(cursor) if cursor else None, "n": limit + 1},
    )
    return page(rows, limit)


async def decision(
    conn, actor, institute, identifier, body, version, key, settings, request_id, *, approve
):
    a = await get_attempt(conn, institute, identifier)
    await review_access(conn, actor, institute, a["student_id"])
    await lock_student(conn, a["student_id"])
    a = await get_attempt(conn, institute, identifier)
    route = f"/v1/biometric-enrollments/{identifier}/" + ("approve" if approve else "reject")
    cached, fingerprint = await idempotent(
        conn, actor, institute, route, key, {"body": body.model_dump(), "version": version}
    )
    if cached:
        return await attempt_view(conn, institute, identifier)
    asset = await one(
        conn,
        "SELECT * FROM app.media_assets WHERE institute_id=:i AND id=:id",
        {"i": institute, "id": a["asset_id"]},
    )
    valid = await one(
        conn,
        "SELECT id FROM app.consents WHERE institute_id=:i AND id=:c AND withdrawn_at IS NULL",
        {"i": institute, "c": a["consent_id"]},
    )
    if (
        a["version"] != version
        or a["status"] != "review_required"
        or asset["expires_at"] <= now()
        or asset["status"] != "uploaded"
        or not valid
    ):
        raise APIError(
            409,
            "REVIEW_UNAVAILABLE",
            "Refresh this enrolment. Expired video requires a fresh recording.",
        )
    eligibility = await one(
        conn, "SELECT app.biometric_student_active(:s) AS active", {"s": a["student_id"]}
    )
    if not eligibility["active"]:
        raise APIError(409, "STUDENT_INACTIVE", "The student is not active.")
    candidate = await one(
        conn,
        "SELECT * FROM app.template_sets WHERE institute_id=:i AND attempt_id=:a AND status='review_required'",
        {"i": institute, "a": identifier},
    )
    payload = (
        await one(
            conn,
            "SELECT count(*) AS n FROM app.face_templates WHERE institute_id=:i AND template_set_id=:id",
            {"i": institute, "id": candidate["id"]},
        )
        if candidate
        else None
    )
    compatible = await one(
        conn,
        "SELECT p.id FROM app.recognition_profiles p JOIN app.model_releases m ON m.institute_id=p.institute_id AND m.id=p.model_release_id WHERE p.institute_id=:i AND p.id=:p AND p.status='enabled' AND m.status='enabled'",
        {"i": institute, "p": a["recognition_profile_id"]},
    )
    if not candidate or not compatible or not payload or not 3 <= payload["n"] <= 5:
        raise APIError(
            409, "TEMPLATES_UNAVAILABLE", "No compatible candidate templates are available."
        )
    if approve:
        await conn.execute(
            text(
                "UPDATE app.template_sets SET status='revoked',revoked_at=now(),version=version+1 WHERE institute_id=:i AND student_id=:s AND model_release_id=:m AND status='active'"
            ),
            {"i": institute, "s": a["student_id"], "m": a["model_release_id"]},
        )
        await conn.execute(
            text(
                "DELETE FROM app.face_templates f USING app.template_sets t WHERE f.institute_id=:i AND t.institute_id=f.institute_id AND t.id=f.template_set_id AND t.student_id=:s AND t.status='revoked'"
            ),
            {"i": institute, "s": a["student_id"]},
        )
    status = "active" if approve else "rejected"
    if approve:
        await conn.execute(
            text(
                "UPDATE app.template_sets SET status='active',revoked_at=NULL,activated_at=now(),version=version+1 WHERE institute_id=:i AND id=:id"
            ),
            {"i": institute, "id": candidate["id"]},
        )
        await conn.execute(text("SELECT app.bump_template_epoch(:s)"), {"s": a["student_id"]})
    else:
        await conn.execute(
            text(
                "UPDATE app.template_sets SET status='rejected',version=version+1 WHERE institute_id=:i AND id=:id"
            ),
            {"i": institute, "id": candidate["id"]},
        )
        await conn.execute(
            text("DELETE FROM app.face_templates WHERE institute_id=:i AND template_set_id=:id"),
            {"i": institute, "id": candidate["id"]},
        )
    await conn.execute(
        text(
            "UPDATE app.enrollment_attempts SET status=:status,reviewed_by=:actor,reason=:reason,version=version+1 WHERE institute_id=:i AND id=:id"
        ),
        {
            "status": status,
            "actor": actor,
            "reason": None if approve else body.reason,
            "i": institute,
            "id": identifier,
        },
    )
    await conn.execute(
        text(
            "UPDATE app.media_assets SET status='delete_pending' WHERE institute_id=:i AND id=:id"
        ),
        {"i": institute, "id": asset["id"]},
    )
    await remember(conn, actor, institute, route, key, fingerprint, {"id": str(identifier)})
    await audit(
        conn, actor, institute, "enrollment." + status, "enrollment_attempt", identifier, request_id
    )
    return await attempt_view(conn, institute, identifier)
