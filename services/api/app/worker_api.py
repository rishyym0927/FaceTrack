"""Internal lease protocol. No user-token or client-supplied tenant trust."""

import hashlib
import json
from contextlib import asynccontextmanager
from datetime import timedelta
from uuid import uuid4

from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from sqlalchemy import text

from . import biometrics as bio
from .db import many, one, transaction
from .errors import APIError


@asynccontextmanager
async def worker_transaction(engine, token):
    if not token or not token.startswith("ftw_") or len(token) > 256:
        raise APIError(401, "WORKER_REQUIRED", "A worker credential is required.")
    hashed = hashlib.sha256(token.encode()).hexdigest()
    async with transaction(engine, None) as conn:
        await conn.execute(
            text("SELECT set_config('app.worker_token_hash',:h,true)"), {"h": hashed}
        )
        worker = await one(
            conn,
            "SELECT * FROM app.worker_identities WHERE token_hash=:h AND status='active' AND expires_at>now()",
            {"h": hashed},
        )
        if not worker:
            raise APIError(401, "WORKER_REQUIRED", "Worker credential is unavailable.")
        await conn.execute(
            text("SELECT set_config('app.institute_id',:i,true)"),
            {"i": str(worker["institute_id"])},
        )
        await conn.execute(
            text("UPDATE app.worker_identities SET last_seen_at=now() WHERE id=:id"),
            {"id": worker["id"]},
        )
        yield conn, worker


async def leased(conn, worker, job_id, epoch, *, succeeded=False):
    job = await one(
        conn,
        "SELECT * FROM app.jobs WHERE institute_id=:i AND id=:id FOR UPDATE",
        {"i": worker["institute_id"], "id": job_id},
    )
    if not job or job["lease_owner"] != worker["id"] or job["lease_epoch"] != epoch:
        raise APIError(409, "STALE_LEASE", "Job lease is unavailable.")
    if job["kind"] not in worker["allowed_kinds"]:
        raise APIError(403, "WORKER_CAPABILITY", "Worker capability was revoked.")
    if succeeded and job["state"] == "succeeded":
        return job
    if job["state"] not in ("leased", "running") or job["lease_expires_at"] <= bio.now():
        raise APIError(409, "STALE_LEASE", "Job lease expired.")
    return job


async def reconcile(conn, worker):
    i = worker["institute_id"]
    # All mutations use the same per-student advisory lock as consent/approval.
    candidates = await many(
        conn,
        "SELECT id,student_id,asset_id,status FROM app.enrollment_attempts WHERE institute_id=:i AND status IN ('awaiting_upload','queued','processing','review_required') ORDER BY id LIMIT 100",
        {"i": i},
    )
    for a in candidates:
        await bio.lock_student(conn, a["student_id"])
        asset = await one(
            conn,
            "SELECT * FROM app.media_assets WHERE institute_id=:i AND id=:id",
            {"i": i, "id": a["asset_id"]},
        )
        current = await bio.get_attempt(conn, i, a["id"])
        expired = asset["expires_at"] <= bio.now() or (
            current["status"] == "awaiting_upload" and asset["reservation_expires_at"] <= bio.now()
        )
        if expired and current["status"] in bio.UNFINISHED:
            await conn.execute(
                text(
                    "UPDATE app.enrollment_attempts SET status='expired',reason='Video or reservation expired; record again.',version=version+1 WHERE institute_id=:i AND id=:id"
                ),
                {"i": i, "id": a["id"]},
            )
            await conn.execute(
                text(
                    "UPDATE app.jobs SET state='cancelled',stage='expired' WHERE institute_id=:i AND enrollment_attempt_id=:a AND state NOT IN ('succeeded','failed','cancelled')"
                ),
                {"i": i, "a": a["id"]},
            )
            await conn.execute(
                text(
                    "UPDATE app.template_sets SET status='revoked',revoked_at=now() WHERE institute_id=:i AND attempt_id=:a AND status='review_required'"
                ),
                {"i": i, "a": a["id"]},
            )
            await conn.execute(
                text(
                    "DELETE FROM app.face_templates f USING app.template_sets t WHERE f.institute_id=:i AND t.institute_id=f.institute_id AND t.id=f.template_set_id AND t.attempt_id=:a AND t.status='revoked'"
                ),
                {"i": i, "a": a["id"]},
            )
            await conn.execute(
                text(
                    "UPDATE app.media_assets SET status='delete_pending' WHERE institute_id=:i AND id=:id"
                ),
                {"i": i, "id": asset["id"]},
            )
    await conn.execute(
        text("""UPDATE app.jobs SET state=CASE WHEN attempts>=3 THEN 'failed' ELSE 'retry_wait' END,
        stage='lease_expired',error_code='LEASE_EXPIRED',available_at=now()+interval '5 seconds'
        WHERE institute_id=:i AND state IN ('leased','running') AND lease_expires_at<=now()"""),
        {"i": i},
    )
    await conn.execute(
        text("""UPDATE app.enrollment_attempts a SET status='failed',reason='Worker retries exhausted.',version=a.version+1
        FROM app.jobs j WHERE j.institute_id=:i AND j.enrollment_attempt_id=a.id AND a.institute_id=j.institute_id
        AND j.state='failed' AND a.status IN ('queued','processing')"""),
        {"i": i},
    )
    await conn.execute(
        text(
            "UPDATE app.media_assets SET status='delete_pending' WHERE institute_id=:i AND expires_at<=now() AND status NOT IN ('deleted','delete_pending')"
        ),
        {"i": i},
    )
    await conn.execute(
        text(
            "UPDATE app.captures c SET status='expired',version=c.version+1 FROM app.media_assets m WHERE c.institute_id=:i AND m.institute_id=c.institute_id AND m.id=c.asset_id AND c.status='awaiting_upload' AND m.reservation_expires_at<=now()"
        ),
        {"i": i},
    )
    await conn.execute(
        text(
            "UPDATE app.media_assets m SET status='delete_pending' FROM app.captures c WHERE c.institute_id=:i AND m.institute_id=c.institute_id AND m.id=c.asset_id AND c.status='expired' AND m.status<>'deleted'"
        ),
        {"i": i},
    )
    await conn.execute(
        text(
            "UPDATE app.captures c SET status='failed',quality_json='{\"error_code\":\"LEASE_EXPIRED\"}',version=c.version+1 FROM app.jobs j WHERE c.institute_id=:i AND j.institute_id=c.institute_id AND j.capture_id=c.id AND j.state='failed' AND c.status IN ('queued','processing')"
        ),
        {"i": i},
    )
    await conn.execute(
        text(
            "UPDATE app.reports r SET status='failed' FROM app.jobs j WHERE r.institute_id=:i AND j.institute_id=r.institute_id AND j.report_id=r.id AND j.state='failed' AND r.status='queued'"
        ),
        {"i": i},
    )
    await conn.execute(
        text(
            "UPDATE app.deliveries d SET status='failed',error_code='LEASE_EXPIRED' FROM app.jobs j WHERE d.institute_id=:i AND j.institute_id=d.institute_id AND j.delivery_id=d.id AND j.state='failed' AND d.status IN ('queued','sending')"
        ),
        {"i": i},
    )
    await conn.execute(
        text(
            "UPDATE app.timetable_imports t SET status='rejected',preview_json='{\"errors\":[{\"code\":\"LEASE_EXPIRED\",\"message\":\"Worker retries exhausted; upload again.\"}]}' FROM app.jobs j WHERE t.institute_id=:i AND j.institute_id=t.institute_id AND j.timetable_import_id=t.id AND j.state='failed' AND t.status IN ('queued','validating')"
        ),
        {"i": i},
    )
    overdue = await one(
        conn,
        "SELECT count(*) AS n FROM app.media_assets WHERE institute_id=:i AND status<>'deleted' AND expires_at<=now()",
        {"i": i},
    )
    return {"overdue_media": overdue["n"]}


async def claim(conn, worker):
    if not set(worker["allowed_kinds"]) & {
        "enrollment",
        "recognition",
        "report",
        "timetable",
        "delivery",
    }:
        raise APIError(403, "WORKER_CAPABILITY", "Worker lacks enrolment capability.")
    # One lease per worker prevents retries/agent restarts from oversubscribing the CPU slot.
    await conn.execute(
        text("SELECT pg_advisory_xact_lock(hashtextextended(:v,0))"),
        {"v": "worker:" + str(worker["id"])},
    )
    existing = await one(
        conn,
        "SELECT id FROM app.jobs WHERE institute_id=:i AND lease_owner=:w AND state IN ('leased','running') AND lease_expires_at>now()",
        {"i": worker["institute_id"], "w": worker["id"]},
    )
    if existing:
        return None
    if "enrollment" not in worker["allowed_kinds"]:
        from .recognition_jobs import claim as recognition_claim

        return await recognition_claim(conn, worker)
    job = await one(
        conn,
        """SELECT j.* FROM app.jobs j
        JOIN app.enrollment_attempts a ON a.institute_id=j.institute_id AND a.id=j.enrollment_attempt_id
        JOIN app.model_releases m ON m.institute_id=a.institute_id AND m.id=a.model_release_id
        JOIN app.recognition_profiles p ON p.institute_id=a.institute_id AND p.id=a.recognition_profile_id
        JOIN app.consents c ON c.institute_id=a.institute_id AND c.id=a.consent_id
        JOIN app.media_assets v ON v.institute_id=a.institute_id AND v.id=a.asset_id
        WHERE j.institute_id=:i AND j.state IN ('queued','retry_wait') AND j.available_at<=now() AND j.attempts<3
        AND a.status IN ('queued','processing') AND c.withdrawn_at IS NULL AND v.expires_at>now()
        AND m.status='enabled' AND p.status='enabled' AND CAST(:hashes AS jsonb) ? m.manifest_hash
        AND app.biometric_student_active(a.student_id)
        ORDER BY j.created_at FOR UPDATE OF j SKIP LOCKED LIMIT 1""",
        {"i": worker["institute_id"], "hashes": json.dumps(worker["allowed_model_hashes"])},
    )
    if not job:
        from .recognition_jobs import claim as recognition_claim

        return await recognition_claim(conn, worker)
    return dict(
        await one(
            conn,
            """UPDATE app.jobs SET state='leased',stage='leased',attempts=attempts+1,
        lease_epoch=lease_epoch+1,lease_owner=:w,lease_expires_at=now()+interval '120 seconds'
        WHERE institute_id=:i AND id=:id RETURNING id,lease_epoch,generation""",
            {"w": worker["id"], "i": worker["institute_id"], "id": job["id"]},
        )
    )


async def progress(conn, worker, identifier, epoch, *, start=False):
    await lock_job_student(conn, worker, identifier)
    job = await leased(conn, worker, identifier, epoch)
    stage = "processing" if start else job["stage"]
    await conn.execute(
        text(
            "UPDATE app.jobs SET state='running',stage=:s,lease_expires_at=now()+interval '120 seconds' WHERE institute_id=:i AND id=:id"
        ),
        {"s": stage, "i": worker["institute_id"], "id": identifier},
    )
    if start and job["kind"] == "recognition":
        await conn.execute(
            text(
                "UPDATE app.captures SET status='processing',version=version+1 WHERE institute_id=:i AND id=:id AND status IN ('queued','processing')"
            ),
            {"i": worker["institute_id"], "id": job["capture_id"]},
        )
    if start:
        await conn.execute(
            text(
                "UPDATE app.enrollment_attempts SET status='processing',version=version+1 WHERE institute_id=:i AND id=:a AND status IN ('queued','processing')"
            ),
            {"i": worker["institute_id"], "a": job["enrollment_attempt_id"]},
        )
    return {"state": "running"}


async def input_data(conn, worker, identifier, epoch):
    job = await leased(conn, worker, identifier, epoch)
    a = await bio.get_attempt(conn, worker["institute_id"], job["enrollment_attempt_id"])
    row = await one(
        conn,
        """SELECT m.manifest_hash,p.settings_hash,p.settings_json FROM app.model_releases m
        JOIN app.recognition_profiles p ON p.institute_id=m.institute_id AND p.model_release_id=m.id
        WHERE m.institute_id=:i AND m.id=:m AND p.id=:p AND m.status='enabled' AND p.status='enabled'""",
        {"i": worker["institute_id"], "m": a["model_release_id"], "p": a["recognition_profile_id"]},
    )
    consent = await one(
        conn,
        "SELECT withdrawn_at FROM app.consents WHERE institute_id=:i AND id=:c",
        {"i": worker["institute_id"], "c": a["consent_id"]},
    )
    asset = await one(
        conn,
        "SELECT * FROM app.media_assets WHERE institute_id=:i AND id=:id",
        {"i": worker["institute_id"], "id": a["asset_id"]},
    )
    if (
        not row
        or row["manifest_hash"] not in worker["allowed_model_hashes"]
        or consent["withdrawn_at"]
        or a["status"] not in ("queued", "processing")
        or asset["expires_at"] <= bio.now()
    ):
        raise APIError(409, "JOB_INPUT_REVOKED", "Job input is no longer available.")
    return a, dict(asset), dict(row)


async def complete(conn, worker, identifier, body, settings):
    # Read attempt without a row lock; take student lock before job lock consistently.
    lookup = await one(
        conn,
        "SELECT a.student_id FROM app.jobs j JOIN app.enrollment_attempts a ON a.institute_id=j.institute_id AND a.id=j.enrollment_attempt_id WHERE j.institute_id=:i AND j.id=:id",
        {"i": worker["institute_id"], "id": identifier},
    )
    if not lookup:
        other = await one(
            conn,
            "SELECT id FROM app.jobs WHERE institute_id=:i AND id=:id AND kind IN ('report','timetable','delivery')",
            {"i": worker["institute_id"], "id": identifier},
        )
        if other:
            return
        raise APIError(404, "NOT_FOUND", "Job not found.")
    await bio.lock_student(conn, lookup["student_id"])
    job = await leased(conn, worker, identifier, body.epoch, succeeded=True)
    result_hash = bio.digest(body.model_dump(exclude={"epoch"}))
    if job["state"] == "succeeded":
        if job["result_hash"] != result_hash:
            raise APIError(409, "RESULT_CONFLICT", "A different result was already committed.")
        return {"state": "succeeded"}
    a, asset, config = await input_data(conn, worker, identifier, body.epoch)
    active = await one(
        conn, "SELECT app.biometric_student_active(:s) AS active", {"s": a["student_id"]}
    )
    if (
        not active["active"]
        or body.generation != job["generation"]
        or body.generation != a["generation"]
        or body.source_sha256 != asset["sha256"]
        or body.model_hash != config["manifest_hash"]
        or body.profile_hash != config["settings_hash"]
    ):
        raise APIError(409, "INPUT_CHANGED", "Result does not match current enrolment input.")
    if settings.template_key_id not in settings.template_keys:
        raise APIError(
            503, "TEMPLATE_KEY_UNAVAILABLE", "Template encryption is unavailable.", retryable=True
        )
    key = bytes.fromhex(settings.template_keys[settings.template_key_id].get_secret_value())
    set_id = uuid4()
    await conn.execute(
        text("""INSERT INTO app.template_sets(id,institute_id,student_id,attempt_id,model_release_id,recognition_profile_id)
        VALUES(:id,:i,:s,:a,:m,:p)"""),
        {
            "id": set_id,
            "i": worker["institute_id"],
            "s": a["student_id"],
            "a": a["id"],
            "m": a["model_release_id"],
            "p": a["recognition_profile_id"],
        },
    )
    for template in body.templates:
        import os

        nonce = os.urandom(12)
        aad = f"{worker['institute_id']}:{a['student_id']}:{set_id}:{a['model_release_id']}:{template.ordinal}".encode()
        encrypted = AESGCM(key).encrypt(
            nonce, json.dumps(template.vector, allow_nan=False).encode(), aad
        )
        await conn.execute(
            text("""INSERT INTO app.face_templates(institute_id,template_set_id,ordinal,ciphertext,nonce,key_id,dimension,preprocess_version)
            VALUES(:i,:s,:o,:c,:n,:k,512,:p)"""),
            {
                "i": worker["institute_id"],
                "s": set_id,
                "o": template.ordinal,
                "c": encrypted,
                "n": nonce,
                "k": settings.template_key_id,
                "p": config["manifest_hash"],
            },
        )
    quality = {
        "counts": body.quality,
        "timings": body.timings,
        "source_sha256": body.source_sha256,
        "processed_sha256": body.processed_sha256,
        "pose_verification": "human_review_required",
    }
    await conn.execute(
        text(
            "UPDATE app.enrollment_attempts SET status='review_required',quality_json=CAST(:q AS jsonb),version=version+1 WHERE institute_id=:i AND id=:a"
        ),
        {"q": json.dumps(quality), "i": worker["institute_id"], "a": a["id"]},
    )
    await conn.execute(
        text(
            "UPDATE app.jobs SET state='succeeded',stage='review_required',result_hash=:h WHERE institute_id=:i AND id=:id"
        ),
        {"h": result_hash, "i": worker["institute_id"], "id": identifier},
    )
    await audit_worker(conn, worker, identifier, "job.processed")
    return {"state": "succeeded"}


async def fail(conn, worker, identifier, body):
    await lock_job_student(conn, worker, identifier)
    job = await leased(conn, worker, identifier, body.epoch)
    retry = (
        body.retryable
        and job["attempts"] < 3
        and body.code in ("DOWNLOAD_UNAVAILABLE", "PROCESS_TIMEOUT", "WORKER_ERROR")
    )
    state = "retry_wait" if retry else "failed"
    await conn.execute(
        text(
            "UPDATE app.jobs SET state=:s,stage=:s,error_code=:c,available_at=:at WHERE institute_id=:i AND id=:id"
        ),
        {
            "s": state,
            "c": body.code,
            "at": bio.now() + timedelta(seconds=5 if job["attempts"] == 1 else 30),
            "i": worker["institute_id"],
            "id": identifier,
        },
    )
    if not retry:
        await conn.execute(
            text(
                "UPDATE app.enrollment_attempts SET status='failed',reason=:r,version=version+1 WHERE institute_id=:i AND id=:a AND status IN ('queued','processing')"
            ),
            {"r": body.code, "i": worker["institute_id"], "a": job["enrollment_attempt_id"]},
        )
        await conn.execute(
            text(
                "UPDATE app.media_assets m SET status='delete_pending' FROM app.enrollment_attempts a WHERE m.institute_id=:i AND a.institute_id=m.institute_id AND a.asset_id=m.id AND a.id=:a"
            ),
            {"i": worker["institute_id"], "a": job["enrollment_attempt_id"]},
        )
    if job["kind"] == "recognition" and not retry:
        await conn.execute(
            text(
                "UPDATE app.captures SET status='failed',quality_json=CAST(:q AS jsonb),version=version+1 WHERE institute_id=:i AND id=:id"
            ),
            {
                "q": json.dumps({"error_code": body.code}),
                "i": worker["institute_id"],
                "id": job["capture_id"],
            },
        )
        await conn.execute(
            text(
                "UPDATE app.media_assets m SET status='delete_pending' FROM app.captures c WHERE m.institute_id=:i AND c.institute_id=m.institute_id AND c.asset_id=m.id AND c.id=:id"
            ),
            {"i": worker["institute_id"], "id": job["capture_id"]},
        )
    if not retry and job["kind"] in ("report", "timetable", "delivery"):
        if job["kind"] == "report":
            await conn.execute(
                text("UPDATE app.reports SET status='failed' WHERE institute_id=:i AND id=:id"),
                {"i": worker["institute_id"], "id": job["report_id"]},
            )
        elif job["kind"] == "timetable":
            await conn.execute(
                text(
                    "UPDATE app.timetable_imports SET status='rejected',preview_json=CAST(:q AS jsonb),version=version+1 WHERE institute_id=:i AND id=:id"
                ),
                {
                    "i": worker["institute_id"],
                    "id": job["timetable_import_id"],
                    "q": json.dumps(
                        {
                            "errors": [
                                {
                                    "code": body.code,
                                    "message": "CSV validation failed. Check the template and upload a corrected file.",
                                }
                            ]
                        }
                    ),
                },
            )
        else:
            await conn.execute(
                text(
                    "UPDATE app.deliveries SET status='failed',error_code=:code,attempts=attempts+1 WHERE institute_id=:i AND id=:id"
                ),
                {"i": worker["institute_id"], "id": job["delivery_id"], "code": body.code},
            )
    await audit_worker(
        conn, worker, identifier, "capture.failed" if job["kind"] == "recognition" else "job.failed"
    )
    return {"state": state}


async def audit_worker(conn, worker, job, action):
    await conn.execute(
        text(
            "INSERT INTO app.audit_events(institute_id,actor_id,action,resource_type,resource_id,request_id,summary) VALUES(:i,NULL,:a,'job',:j,:r,CAST(:s AS jsonb))"
        ),
        {
            "i": worker["institute_id"],
            "a": action,
            "j": job,
            "r": str(uuid4()),
            "s": json.dumps({"worker_id": str(worker["id"])}),
        },
    )


async def lock_job_student(conn, worker, identifier):
    row = await one(
        conn,
        "SELECT a.student_id FROM app.jobs j JOIN app.enrollment_attempts a ON a.institute_id=j.institute_id AND a.id=j.enrollment_attempt_id WHERE j.institute_id=:i AND j.id=:id",
        {"i": worker["institute_id"], "id": identifier},
    )
    if not row:
        capture = await one(
            conn,
            "SELECT c.session_id FROM app.jobs j JOIN app.captures c ON c.institute_id=j.institute_id AND c.id=j.capture_id WHERE j.institute_id=:i AND j.id=:id",
            {"i": worker["institute_id"], "id": identifier},
        )
        if capture:
            await one(
                conn,
                "SELECT id FROM app.sessions WHERE institute_id=:i AND id=:id FOR UPDATE",
                {"i": worker["institute_id"], "id": capture["session_id"]},
            )
            return
        other = await one(
            conn,
            "SELECT id FROM app.jobs WHERE institute_id=:i AND id=:id AND kind IN ('report','timetable','delivery')",
            {"i": worker["institute_id"], "id": identifier},
        )
        if other:
            return
        raise APIError(404, "NOT_FOUND", "Job not found.")
    await bio.lock_student(conn, row["student_id"])
