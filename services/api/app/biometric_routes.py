from typing import Annotated
from uuid import UUID

from fastapi import Depends, Header, Query, Request, Response
from sqlalchemy import text

from . import biometric_types as types
from . import biometrics as bio
from . import documents
from . import recognition_jobs as recognition
from . import worker_api as work
from .db import many, one, transaction
from .errors import APIError
from .security import expected_version, idempotent


def install(app, engine, settings, principal, storage):
    User = Annotated[object, Depends(principal)]
    Institute = Annotated[UUID, Header(alias="X-Institute-ID")]
    Key = Annotated[str, Header(alias="Idempotency-Key", min_length=1, max_length=128)]
    Version = Annotated[str, Header(alias="If-Match")]

    @app.get("/v1/privacy/notice")
    async def notice():
        return {"version": bio.NOTICE_VERSION, "hash": bio.NOTICE_HASH, "text": bio.NOTICE}

    @app.get("/v1/me/biometric-enrollment")
    async def own(user: User, institute_id: Institute):
        async with transaction(engine, user.user_id, institute_id) as conn:
            return await bio.own_state(conn, user.user_id, institute_id)

    @app.post("/v1/consents", status_code=201)
    async def accept(
        body: types.ConsentAccept, request: Request, user: User, institute_id: Institute, key: Key
    ):
        async with transaction(engine, user.user_id, institute_id) as conn:
            return await bio.accept(
                conn, user.user_id, institute_id, body, key, request.state.request_id
            )

    @app.delete("/v1/consents/{identifier}")
    async def withdraw(identifier: UUID, request: Request, user: User, institute_id: Institute):
        async with transaction(engine, user.user_id, institute_id) as conn:
            return await bio.withdraw(
                conn, user.user_id, institute_id, identifier, request.state.request_id
            )

    @app.post("/v1/biometric-enrollments", status_code=201)
    async def create(
        body: types.EnrollmentCreate,
        request: Request,
        user: User,
        institute_id: Institute,
        key: Key,
    ):
        async with transaction(engine, user.user_id, institute_id) as conn:
            return await bio.create(
                conn, user.user_id, institute_id, body, key, settings, request.state.request_id
            )

    @app.get("/v1/biometric-enrollments/{identifier}")
    async def detail(identifier: UUID, user: User, institute_id: Institute):
        async with transaction(engine, user.user_id, institute_id) as conn:
            a = await bio.get_attempt(conn, institute_id, identifier)
            own = await one(
                conn,
                "SELECT id FROM app.students WHERE institute_id=:i AND id=:s AND auth_user_id=:u",
                {"i": institute_id, "s": a["student_id"], "u": user.user_id},
            )
            if own:
                await bio.student(conn, user.user_id, institute_id)
            else:
                await bio.review_access(conn, user.user_id, institute_id, a["student_id"])
            return await bio.attempt_view(conn, institute_id, identifier)

    @app.post("/v1/biometric-enrollments/{identifier}/upload-grant")
    async def upload_grant(
        identifier: UUID, body: types.UploadMetadata, user: User, institute_id: Institute
    ):
        async with transaction(engine, user.user_id, institute_id) as conn:
            s = await bio.student(conn, user.user_id, institute_id)
            await bio.lock_student(conn, s["id"])
            _, asset = await bio.owned_asset(conn, user.user_id, institute_id, identifier)
            if asset["grant_expires_at"] and (
                body.expected_bytes != asset["expected_bytes"]
                or body.mime_type != asset["mime_type"]
            ):
                raise APIError(409, "MEDIA_CHANGED", "Start a new recording for a changed file.")
            await conn.execute(
                text(
                    "UPDATE app.media_assets SET expected_bytes=:n,mime_type=:m WHERE institute_id=:i AND id=:id"
                ),
                {
                    "n": body.expected_bytes,
                    "m": body.mime_type,
                    "i": institute_id,
                    "id": asset["id"],
                },
            )
            _, asset = await bio.owned_asset(
                conn, user.user_id, institute_id, identifier, grant=True
            )
        return await storage.upload(asset)

    @app.post("/v1/biometric-enrollments/{identifier}/upload-complete", status_code=202)
    async def upload_complete(
        identifier: UUID,
        body: types.UploadComplete,
        request: Request,
        user: User,
        institute_id: Institute,
        key: Key,
    ):
        async with transaction(engine, user.user_id, institute_id) as conn:
            _, asset = await bio.owned_asset(conn, user.user_id, institute_id, identifier)
            cached, _ = await idempotent(
                conn,
                user.user_id,
                institute_id,
                f"/v1/biometric-enrollments/{identifier}/upload-complete",
                key,
                body.model_dump(),
            )
            if cached:
                return cached
        info = await storage.info(asset)
        async with transaction(engine, user.user_id, institute_id) as conn:
            return await bio.upload_complete(
                conn,
                user.user_id,
                institute_id,
                identifier,
                body,
                info,
                key,
                request.state.request_id,
            )

    @app.post("/v1/biometric-enrollments/{identifier}/cancel")
    async def cancel(
        identifier: UUID, request: Request, user: User, institute_id: Institute, version: Version
    ):
        async with transaction(engine, user.user_id, institute_id) as conn:
            return await bio.cancel(
                conn,
                user.user_id,
                institute_id,
                identifier,
                expected_version(version),
                request.state.request_id,
            )

    @app.get("/v1/offerings/{offering}/biometric-enrollments")
    async def review_list(
        offering: UUID,
        user: User,
        institute_id: Institute,
        cursor: UUID | None = None,
        limit: Annotated[int, Query(ge=1, le=200)] = 50,
    ):
        async with transaction(engine, user.user_id, institute_id) as conn:
            return await bio.review_list(conn, user.user_id, institute_id, offering, cursor, limit)

    @app.post("/v1/biometric-enrollments/{identifier}/approve")
    async def approve(
        identifier: UUID,
        body: types.Approval,
        request: Request,
        user: User,
        institute_id: Institute,
        key: Key,
        version: Version,
    ):
        async with transaction(engine, user.user_id, institute_id) as conn:
            return await bio.decision(
                conn,
                user.user_id,
                institute_id,
                identifier,
                body,
                expected_version(version),
                key,
                settings,
                request.state.request_id,
                approve=True,
            )

    @app.post("/v1/biometric-enrollments/{identifier}/reject")
    async def reject(
        identifier: UUID,
        body: types.Rejection,
        request: Request,
        user: User,
        institute_id: Institute,
        key: Key,
        version: Version,
    ):
        async with transaction(engine, user.user_id, institute_id) as conn:
            return await bio.decision(
                conn,
                user.user_id,
                institute_id,
                identifier,
                body,
                expected_version(version),
                key,
                settings,
                request.state.request_id,
                approve=False,
            )

    @app.get("/v1/biometric-enrollments/{identifier}/review-video")
    async def video(identifier: UUID, user: User, institute_id: Institute):
        async with transaction(engine, user.user_id, institute_id) as conn:
            a = await bio.get_attempt(conn, institute_id, identifier)
            await bio.review_access(conn, user.user_id, institute_id, a["student_id"])
            asset = await one(
                conn,
                "SELECT * FROM app.media_assets WHERE institute_id=:i AND id=:id",
                {"i": institute_id, "id": a["asset_id"]},
            )
            consent = await one(
                conn,
                "SELECT withdrawn_at FROM app.consents WHERE institute_id=:i AND id=:c",
                {"i": institute_id, "c": a["consent_id"]},
            )
            if (
                a["status"] != "review_required"
                or consent["withdrawn_at"]
                or asset["status"] != "uploaded"
                or asset["expires_at"] <= bio.now()
            ):
                raise APIError(
                    409,
                    "VIDEO_EXPIRED",
                    "Review video is unavailable; a new recording may be required.",
                )
            asset = dict(asset)
        return {"url": await storage.download(asset), "expires_in": 60}

    @app.get("/v1/jobs/{identifier}")
    async def job(identifier: UUID, user: User, institute_id: Institute):
        async with transaction(engine, user.user_id, institute_id) as conn:
            j = await one(
                conn,
                "SELECT id,state,stage,error_code,enrollment_attempt_id,capture_id,report_id,timetable_import_id,delivery_id FROM app.jobs WHERE institute_id=:i AND id=:id",
                {"i": institute_id, "id": identifier},
            )
            if not j:
                raise APIError(404, "NOT_FOUND", "Job not found.")
            if j["timetable_import_id"]:
                owned = await one(
                    conn,
                    "SELECT uploaded_by FROM app.timetable_imports WHERE institute_id=:i AND id=:id",
                    {"i": institute_id, "id": j["timetable_import_id"]},
                )
                if not owned or owned["uploaded_by"] != user.user_id:
                    raise APIError(404, "NOT_FOUND", "Job not found.")
                return {k: j[k] for k in ("id", "state", "stage", "error_code")}
            if j["report_id"] or j["delivery_id"]:
                from .attendance import session

                r = await one(
                    conn,
                    "SELECT session_id FROM app.reports WHERE institute_id=:i AND id=coalesce(CAST(:r AS uuid),(SELECT report_id FROM app.deliveries WHERE institute_id=:i AND id=:d))",
                    {"i": institute_id, "r": j["report_id"], "d": j["delivery_id"]},
                )
                if not r:
                    raise APIError(404, "NOT_FOUND", "Job not found.")
                await session(conn, user.user_id, institute_id, r["session_id"])
                return {k: j[k] for k in ("id", "state", "stage", "error_code")}
            if j["capture_id"]:
                from .attendance import session

                cap = await one(
                    conn,
                    "SELECT session_id FROM app.captures WHERE institute_id=:i AND id=:id",
                    {"i": institute_id, "id": j["capture_id"]},
                )
                await session(conn, user.user_id, institute_id, cap["session_id"])
                return {k: j[k] for k in ("id", "state", "stage", "error_code")}
            a = await bio.get_attempt(conn, institute_id, j["enrollment_attempt_id"])
            s = await one(
                conn,
                "SELECT id FROM app.students WHERE institute_id=:i AND id=:s AND auth_user_id=:a",
                {"i": institute_id, "s": a["student_id"], "a": user.user_id},
            )
            if s:
                await bio.student(conn, user.user_id, institute_id)
            else:
                await bio.review_access(conn, user.user_id, institute_id, a["student_id"])
            return dict(j)

    Worker = Annotated[str, Header(alias="Authorization")]

    def credential(value):
        if not value.startswith("Bearer "):
            raise APIError(401, "WORKER_REQUIRED", "Worker authorization is required.")
        return value[7:]

    @app.post("/internal/v1/jobs/claim")
    async def claim(authorization: Worker):
        async with work.worker_transaction(engine, credential(authorization)) as (conn, worker):
            result = await work.claim(conn, worker)
        return result if result else Response(status_code=204)

    @app.post("/internal/v1/jobs/{identifier}/start")
    async def start(identifier: UUID, body: types.Epoch, authorization: Worker):
        async with work.worker_transaction(engine, credential(authorization)) as (conn, worker):
            return await work.progress(conn, worker, identifier, body.epoch, start=True)

    @app.post("/internal/v1/jobs/{identifier}/heartbeat")
    async def heartbeat(identifier: UUID, body: types.Epoch, authorization: Worker):
        async with work.worker_transaction(engine, credential(authorization)) as (conn, worker):
            return await work.progress(conn, worker, identifier, body.epoch)

    @app.get("/internal/v1/jobs/{identifier}/input")
    async def job_input(identifier: UUID, epoch: int, authorization: Worker):
        async with work.worker_transaction(engine, credential(authorization)) as (conn, worker):
            job = await work.leased(conn, worker, identifier, epoch)
            if job["kind"] in ("report", "timetable", "delivery"):
                data, asset = await documents.input_data(conn, worker, job)
            elif job["kind"] == "recognition":
                data, asset = await recognition.input_data(conn, worker, job, settings)
            else:
                a, asset, config = await work.input_data(conn, worker, identifier, epoch)
                data = None
        if data is not None:
            return {**data, **({"media_url": await storage.download(asset)} if asset else {})}
        return {
            "attempt_id": a["id"],
            "generation": a["generation"],
            "byte_size": asset["byte_size"],
            "source_sha256": asset["sha256"],
            "media_url": await storage.download(asset),
            "model_hash": config["manifest_hash"],
            "profile_hash": config["settings_hash"],
        }

    @app.post("/internal/v1/jobs/{identifier}/complete")
    async def finish(
        identifier: UUID,
        body: types.WorkerComplete | recognition.RecognitionComplete | documents.DocumentComplete,
        authorization: Worker,
    ):
        if isinstance(body, documents.DocumentComplete):
            return await documents.complete(
                engine, credential(authorization), identifier, body, settings, storage
            )
        async with work.worker_transaction(engine, credential(authorization)) as (conn, worker):
            if isinstance(body, recognition.RecognitionComplete):
                return await recognition.complete(conn, worker, identifier, body, settings)
            return await work.complete(conn, worker, identifier, body, settings)

    @app.post("/internal/v1/jobs/{identifier}/fail")
    async def fail(identifier: UUID, body: types.WorkerFailure, authorization: Worker):
        async with work.worker_transaction(engine, credential(authorization)) as (conn, worker):
            return await work.fail(conn, worker, identifier, body)

    @app.post("/internal/v1/maintenance/reconcile")
    async def reconcile(authorization: Worker):
        token = credential(authorization)
        async with work.worker_transaction(engine, token) as (conn, worker):
            result = await work.reconcile(conn, worker)
            # Keep terminal tombstones until after upload tokens expire, cleaning re-created late objects too.
            assets = [
                dict(x)
                for x in await many(
                    conn,
                    "SELECT * FROM app.media_assets WHERE institute_id=:i AND (status='delete_pending' OR (status='deleted' AND grant_expires_at>now())) ORDER BY created_at LIMIT 100",
                    {"i": worker["institute_id"]},
                )
            ]
        failed = 0
        for asset in assets:
            try:
                await storage.delete(asset)
                async with work.worker_transaction(engine, token) as (conn, worker):
                    await conn.execute(
                        text(
                            "UPDATE app.media_assets SET status='deleted',deleted_at=now() WHERE institute_id=:i AND id=:id"
                        ),
                        {"i": worker["institute_id"], "id": asset["id"]},
                    )
            except APIError:
                failed += 1
        return {**result, "deletion_failures": failed}
