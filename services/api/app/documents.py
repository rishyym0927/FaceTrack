"""Durable document jobs, private report artifacts and scoped faculty delivery."""

import base64
import hashlib
import json
from datetime import date, datetime, time, timedelta
from typing import Annotated, Literal
from uuid import UUID, uuid4
from zoneinfo import ZoneInfo

import httpx
from fastapi import Depends, Header, Request
from pydantic import Field
from sqlalchemy import text

from . import biometrics as bio
from .attendance import remember, session
from .biometric_types import Epoch
from .db import many, one, transaction
from .errors import APIError
from .schemas import Strict
from .security import audit, idempotent, roles, teacher_access

CSV_COLUMNS = [
    "entry_key",
    "term_code",
    "course_code",
    "branch",
    "semester",
    "section",
    "teacher_email",
    "room_code",
    "weekday",
    "start_time",
    "end_time",
    "effective_from",
    "effective_until",
    "timezone",
]


class Reservation(Strict):
    purpose: Literal["timetable"]
    mime_type: Literal["text/csv"]
    expected_bytes: int = Field(gt=0, le=1048576)


class ImportCreate(Strict):
    asset_id: UUID
    term_id: UUID
    base_revision: int = Field(ge=0)
    byte_size: int = Field(gt=0, le=1048576)
    sha256: str = Field(pattern=r"^[a-f0-9]{64}$")


class ImportCommit(Strict):
    preview_hash: str = Field(pattern=r"^[a-f0-9]{64}$")
    expected_revision: int = Field(ge=0)
    materialize_date: date


class DocumentComplete(Epoch):
    kind: Literal["report", "timetable"]
    csv_base64: str | None = Field(default=None, max_length=850000)
    pdf_base64: str | None = Field(default=None, max_length=850000)
    rows: list[dict[str, str]] | None = Field(default=None, max_length=500)
    source_sha256: str | None = Field(default=None, pattern=r"^[a-f0-9]{64}$")


class RoomCreate(Strict):
    code: str = Field(min_length=1, max_length=32)
    name: str = Field(min_length=1, max_length=100)
    capacity: int | None = Field(default=None, gt=0, le=1000)


async def enqueue_report(
    conn, actor, institute, snapshot, session_id, source_version, publication_id=None
):
    kind = "final" if publication_id else "draft"
    snapshot = {**snapshot, "kind": kind, "revision": source_version}
    row = await one(
        conn,
        """INSERT INTO app.reports(institute_id,session_id,publication_id,kind,source_version,snapshot_json,snapshot_hash)
    VALUES(:i,:s,:p,:k,:v,CAST(:snap AS jsonb),:h) ON CONFLICT(institute_id,session_id,kind,source_version) DO NOTHING RETURNING *""",
        {
            "i": institute,
            "s": session_id,
            "p": publication_id,
            "k": kind,
            "v": source_version,
            "snap": json.dumps(snapshot, default=str),
            "h": bio.digest(snapshot),
        },
    )
    if not row:
        return
    ids = []
    for extension, mime in [("csv", "text/csv"), ("pdf", "application/pdf")]:
        asset = await one(
            conn,
            """INSERT INTO app.media_assets(institute_id,owner_user_id,purpose,bucket,object_key,mime_type,expected_bytes,expires_at)
        VALUES(:i,:u,'report','facetrack-documents-dev',:key,:mime,1,now()+interval '30 days') RETURNING id""",
            {
                "i": institute,
                "u": actor,
                "key": f"reports/{row['id']}/{uuid4().hex}.{extension}",
                "mime": mime,
            },
        )
        ids.append(asset["id"])
    await conn.execute(
        text(
            "UPDATE app.reports SET csv_asset_id=:c,pdf_asset_id=:p WHERE institute_id=:i AND id=:id"
        ),
        {"i": institute, "id": row["id"], "c": ids[0], "p": ids[1]},
    )
    await conn.execute(
        text(
            "INSERT INTO app.jobs(institute_id,kind,report_id,dedup_key) VALUES(:i,'report',:r,:key)"
        ),
        {"i": institute, "r": row["id"], "key": "report:" + str(row["id"])},
    )


async def claim(conn, worker):
    allowed = set(worker["allowed_kinds"]) & {"report", "timetable", "delivery"}
    if not allowed:
        return None
    job = await one(
        conn,
        """SELECT j.* FROM app.jobs j WHERE j.institute_id=:i AND j.kind=ANY(CAST(:k AS text[])) AND j.state IN ('queued','retry_wait') AND j.attempts<3 AND j.available_at<=now()
    ORDER BY j.created_at FOR UPDATE SKIP LOCKED LIMIT 1""",
        {"i": worker["institute_id"], "k": list(allowed)},
    )
    if not job:
        return None
    return dict(
        await one(
            conn,
            "UPDATE app.jobs SET state='leased',stage='leased',attempts=attempts+1,lease_epoch=lease_epoch+1,lease_owner=:w,lease_expires_at=now()+interval '120 seconds' WHERE institute_id=:i AND id=:id RETURNING id,lease_epoch,generation",
            {"i": worker["institute_id"], "id": job["id"], "w": worker["id"]},
        )
    )


async def input_data(conn, worker, job):
    i = worker["institute_id"]
    kind = job["kind"]
    if kind == "report":
        r = await one(
            conn,
            "SELECT * FROM app.reports WHERE institute_id=:i AND id=:id",
            {"i": i, "id": job["report_id"]},
        )
        if r["expires_at"] <= bio.now():
            raise APIError(409, "REPORT_EXPIRED", "Report expired.")
        return {"kind": "report", "snapshot": r["snapshot_json"]}, None
    if kind == "delivery":
        return {"kind": "delivery"}, None
    r = await one(
        conn,
        "SELECT * FROM app.timetable_imports WHERE institute_id=:i AND id=:id",
        {"i": i, "id": job["timetable_import_id"]},
    )
    asset = await one(
        conn,
        "SELECT * FROM app.media_assets WHERE institute_id=:i AND id=:id",
        {"i": i, "id": r["asset_id"]},
    )
    if r["status"] not in ("queued", "validating") or asset["expires_at"] <= bio.now():
        raise APIError(409, "IMPORT_EXPIRED", "Import unavailable.")
    return {
        "kind": "timetable",
        "byte_size": asset["byte_size"],
        "source_sha256": asset["sha256"],
    }, dict(asset)


async def normalized_rows(conn, institute, term, actor, rows):
    if not rows or len(rows) > 500:
        raise APIError(422, "INVALID_TIMETABLE", "CSV needs 1–500 rows.")
    result = []
    keys = set()
    for raw in rows:
        if set(raw) != set(CSV_COLUMNS) or any(not x or len(x) > 254 for x in raw.values()):
            raise APIError(
                422,
                "INVALID_TIMETABLE",
                "Use all required CSV columns with nonempty bounded fields.",
            )
        try:
            weekday = ["MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"].index(raw["weekday"])
            start = time.fromisoformat(raw["start_time"])
            end = time.fromisoformat(raw["end_time"])
            first = date.fromisoformat(raw["effective_from"])
            last = date.fromisoformat(raw["effective_until"])
            semester = int(raw["semester"])
            if (
                start >= end
                or start.tzinfo
                or end.tzinfo
                or first > last
                or raw["timezone"] != "Asia/Kolkata"
                or len(raw["entry_key"]) > 100
                or raw["entry_key"] in keys
            ):
                raise ValueError()
        except (ValueError, TypeError):
            raise APIError(
                422,
                "INVALID_TIMETABLE",
                "Invalid/duplicate entry key, date, time, weekday or timezone.",
            ) from None
        ref = await one(
            conn,
            """SELECT o.id AS offering_id,t.id AS teacher_id,r.id AS room_id,tm.starts_on,tm.ends_on FROM app.offerings o
        JOIN app.terms tm ON tm.institute_id=o.institute_id AND tm.id=o.term_id JOIN app.courses c ON c.institute_id=o.institute_id AND c.id=o.course_id
        JOIN app.class_groups g ON g.institute_id=o.institute_id AND g.id=o.class_group_id JOIN app.offering_teachers ot ON ot.institute_id=o.institute_id AND ot.offering_id=o.id
        JOIN app.teachers t ON t.institute_id=ot.institute_id AND t.id=ot.teacher_id JOIN app.rooms r ON r.institute_id=o.institute_id AND r.code=:room
        WHERE o.institute_id=:i AND o.term_id=:term AND tm.code=:term_code AND c.code=:course AND g.branch=:branch AND g.semester=:semester AND g.section=:section
        AND t.official_email=:email AND ot.status='active' AND t.status='approved' AND o.status='active'
        AND app.faculty_can_teach(:actor,o.id)""",
            {
                "i": institute,
                "term": term,
                "term_code": raw["term_code"],
                "course": raw["course_code"],
                "branch": raw["branch"],
                "semester": semester,
                "section": raw["section"],
                "email": raw["teacher_email"].lower(),
                "room": raw["room_code"],
                "actor": actor,
            },
        )
        if not ref or first < ref["starts_on"] or last > ref["ends_on"]:
            raise APIError(
                422,
                "TIMETABLE_REFERENCE",
                "An offering, assigned teacher, room or term date is invalid or unauthorized.",
            )
        keys.add(raw["entry_key"])
        result.append(
            {
                **raw,
                "offering_id": str(ref["offering_id"]),
                "teacher_id": str(ref["teacher_id"]),
                "room_id": str(ref["room_id"]),
                "weekday_index": weekday,
            }
        )
    # Include retained entries: an upsert must not introduce conflicts with omitted rows.
    existing = await many(
        conn,
        "SELECT * FROM app.schedule_series WHERE institute_id=:i AND status='active'",
        {"i": institute},
    )
    combined = list(result) + [
        {
            "entry_key": x["entry_key"],
            "teacher_id": str(x["teacher_id"]),
            "room_id": str(x["room_id"]),
            "offering_id": str(x["offering_id"]),
            "weekday_index": x["weekday"],
            "start_time": x["local_start"].isoformat(),
            "end_time": x["local_end"].isoformat(),
            "effective_from": x["effective_from"].isoformat(),
            "effective_until": x["effective_until"].isoformat(),
        }
        for x in existing
        if x["term_id"] != term or x["entry_key"] not in keys
    ]
    for n, a in enumerate(combined):
        for b in combined[n + 1 :]:
            if a["weekday_index"] != b["weekday_index"] or not (
                a["teacher_id"] == b["teacher_id"]
                or a["room_id"] == b["room_id"]
                or a["offering_id"] == b["offering_id"]
            ):
                continue
            first = max(
                date.fromisoformat(a["effective_from"]), date.fromisoformat(b["effective_from"])
            )
            last = min(
                date.fromisoformat(a["effective_until"]), date.fromisoformat(b["effective_until"])
            )
            occurs = first + timedelta(days=(a["weekday_index"] - first.weekday()) % 7) <= last
            if (
                occurs
                and time.fromisoformat(a["start_time"]) < time.fromisoformat(b["end_time"])
                and time.fromisoformat(b["start_time"]) < time.fromisoformat(a["end_time"])
            ):
                raise APIError(409, "TIMETABLE_OVERLAP", "Teacher, room or class periods overlap.")
    return result


async def complete(engine, token, identifier, body, settings, storage):
    from .worker_api import leased, worker_transaction

    async with worker_transaction(engine, token) as (c, w):
        j = await leased(c, w, identifier, body.epoch, succeeded=True)
        if body.kind != j["kind"]:
            raise APIError(409, "JOB_KIND", "Unexpected job result type.")
        fingerprint = bio.digest(body.model_dump(exclude={"epoch"}))
        if j["state"] == "succeeded":
            if fingerprint != j["result_hash"]:
                raise APIError(409, "RESULT_CONFLICT", "Different result already committed.")
            return {"state": "succeeded"}
        if body.kind == "timetable":
            imp = await one(
                c,
                "SELECT * FROM app.timetable_imports WHERE institute_id=:i AND id=:id FOR UPDATE",
                {"i": w["institute_id"], "id": j["timetable_import_id"]},
            )
            if body.source_sha256 != imp["source_hash"]:
                raise APIError(409, "INPUT_CHANGED", "CSV source changed.")
            try:
                rows = await normalized_rows(
                    c, w["institute_id"], imp["term_id"], imp["uploaded_by"], body.rows
                )
                preview = {"rows": rows}
                status = "ready"
            except APIError as error:
                preview = {"errors": [{"code": error.code, "message": error.message}]}
                status = "rejected"
            await c.execute(
                text(
                    "UPDATE app.timetable_imports SET preview_json=CAST(:p AS jsonb),preview_hash=:h,status=:s,version=version+1 WHERE institute_id=:i AND id=:id"
                ),
                {
                    "p": json.dumps(preview),
                    "h": bio.digest(preview),
                    "s": status,
                    "i": w["institute_id"],
                    "id": imp["id"],
                },
            )
            await c.execute(
                text(
                    "UPDATE app.media_assets SET status='delete_pending' WHERE institute_id=:i AND id=:id"
                ),
                {"i": w["institute_id"], "id": imp["asset_id"]},
            )
            await c.execute(
                text(
                    "UPDATE app.jobs SET state='succeeded',stage=:s,result_hash=:h WHERE institute_id=:i AND id=:id"
                ),
                {"s": status, "h": fingerprint, "i": w["institute_id"], "id": identifier},
            )
            return {"state": "succeeded"}
        report = await one(
            c,
            "SELECT * FROM app.reports WHERE institute_id=:i AND id=:id",
            {"i": w["institute_id"], "id": j["report_id"]},
        )
        assets = [
            dict(
                await one(
                    c,
                    "SELECT * FROM app.media_assets WHERE institute_id=:i AND id=:id",
                    {"i": w["institute_id"], "id": report[key]},
                )
            )
            for key in ("csv_asset_id", "pdf_asset_id")
        ]
    try:
        blobs = [
            base64.b64decode(body.csv_base64 or "", validate=True),
            base64.b64decode(body.pdf_base64 or "", validate=True),
        ]
        if (
            not blobs[0]
            or not blobs[1].startswith(b"%PDF-")
            or b"%%EOF" not in blobs[1][-128:]
            or sum(map(len, blobs)) > 650000
        ):
            raise ValueError()
        blobs[0].decode("utf-8-sig")
    except (ValueError, UnicodeError):
        raise APIError(422, "INVALID_REPORT", "Invalid bounded CSV/PDF result.") from None
    # Network writes never hold DB locks. Deterministic opaque reserved keys support safe replay.
    original_assets = assets
    async with worker_transaction(engine, token) as (c, w):
        await leased(c, w, identifier, body.epoch)
        assets = []
        for original, blob in zip(original_assets, blobs):
            asset = dict(
                await one(
                    c,
                    """INSERT INTO app.media_assets(institute_id,owner_user_id,purpose,bucket,object_key,mime_type,expected_bytes,expires_at)
            VALUES(:i,:u,'report',:b,:key,:mime,:n,:expires) RETURNING *""",
                    {
                        "i": w["institute_id"],
                        "u": original["owner_user_id"],
                        "b": original["bucket"],
                        "key": "reports/" + uuid4().hex,
                        "mime": original["mime_type"],
                        "n": len(blob),
                        "expires": original["expires_at"],
                    },
                )
            )
            assets.append(asset)
    for asset, blob in zip(assets, blobs):
        await storage.put(asset, blob)
    async with worker_transaction(engine, token) as (c, w):
        j = await leased(c, w, identifier, body.epoch, succeeded=True)
        if j["state"] == "succeeded":
            if j["result_hash"] != fingerprint:
                raise APIError(409, "RESULT_CONFLICT", "Different result already committed.")
            return {"state": "succeeded"}
        for asset, blob in zip(assets, blobs):
            await c.execute(
                text(
                    "UPDATE app.media_assets SET status='uploaded',expected_bytes=:n,byte_size=:n,sha256=:h WHERE institute_id=:i AND id=:id"
                ),
                {
                    "n": len(blob),
                    "h": hashlib.sha256(blob).hexdigest(),
                    "i": w["institute_id"],
                    "id": asset["id"],
                },
            )
        await c.execute(
            text(
                "UPDATE app.reports SET status='ready',csv_asset_id=:csv,pdf_asset_id=:pdf WHERE institute_id=:i AND id=:id"
            ),
            {
                "i": w["institute_id"],
                "id": j["report_id"],
                "csv": assets[0]["id"],
                "pdf": assets[1]["id"],
            },
        )
        await c.execute(
            text(
                """UPDATE app.media_assets SET status='deleted',deleted_at=now()
                WHERE institute_id=:i AND id IN (:csv,:pdf) AND purpose='report' AND status='reserved'"""
            ),
            {
                "i": w["institute_id"],
                "csv": original_assets[0]["id"],
                "pdf": original_assets[1]["id"],
            },
        )
        await c.execute(
            text(
                "UPDATE app.jobs SET state='succeeded',stage='ready',result_hash=:h WHERE institute_id=:i AND id=:id"
            ),
            {"h": fingerprint, "i": w["institute_id"], "id": identifier},
        )
        return {"state": "succeeded"}


async def deliver(engine, token, identifier, epoch, settings):
    from .worker_api import leased, worker_transaction

    if not settings.resend_api_key.get_secret_value() or not settings.resend_from:
        raise APIError(
            503,
            "EMAIL_NOT_CONFIGURED",
            "Email delivery is not configured; report downloads remain available.",
        )
    async with worker_transaction(engine, token) as (c, w):
        j = await leased(c, w, identifier, epoch, succeeded=True)
        if j["kind"] != "delivery":
            raise APIError(409, "JOB_KIND", "Expected delivery job.")
        d = await one(
            c,
            """SELECT d.*,r.session_id,r.status AS report_status,r.expires_at AS report_expires_at FROM app.deliveries d JOIN app.reports r ON r.institute_id=d.institute_id AND r.id=d.report_id WHERE d.institute_id=:i AND d.id=:id""",
            {"i": w["institute_id"], "id": j["delivery_id"]},
        )
        if d["status"] == "sent":
            return {"state": "succeeded"}
        faculty = await one(
            c,
            """SELECT t.official_email,t.auth_user_id,s.offering_id FROM app.sessions s JOIN app.teachers t ON t.institute_id=s.institute_id AND t.id=s.teacher_id WHERE s.institute_id=:i AND s.id=:s AND t.status='approved' AND app.faculty_can_teach(t.auth_user_id,s.offering_id)""",
            {"i": w["institute_id"], "s": d["session_id"]},
        )
        if (
            not faculty
            or faculty["auth_user_id"] != d["recipient_user_id"]
            or faculty["official_email"] != d["recipient_email"]
            or d["report_status"] != "ready"
            or d["report_expires_at"] <= bio.now()
        ):
            raise APIError(
                409, "RECIPIENT_CHANGED", "Faculty recipient or report is no longer eligible."
            )
        if d["created_at"] + timedelta(hours=23) <= bio.now():
            raise APIError(
                409, "DELIVERY_EXPIRED", "Provider retry window ended; operator review required."
            )
        payload = {
            "from": settings.resend_from,
            "to": [d["recipient_email"]],
            "subject": "FaceTrack attendance report ready",
            "text": f"Your attendance report is ready. Sign in to FaceTrack Teacher to view the published session and download its report: {settings.faculty_report_url.rstrip('/')}/#/sessions/{d['session_id']}\nThis link requires your authorized account.",
        }
    async with httpx.AsyncClient(timeout=12, follow_redirects=False) as client:
        try:
            response = await client.post(
                "https://api.resend.com/emails",
                headers={
                    "Authorization": "Bearer " + settings.resend_api_key.get_secret_value(),
                    "Idempotency-Key": "facetrack-delivery-" + str(d["id"]),
                },
                json=payload,
            )
            response.raise_for_status()
            provider_id = response.json()["id"]
        except (httpx.HTTPError, ValueError, KeyError):
            raise APIError(
                503,
                "EMAIL_UNAVAILABLE",
                "Email provider did not accept this delivery.",
                retryable=True,
            ) from None
    async with worker_transaction(engine, token) as (c, w):
        j = await leased(c, w, identifier, epoch, succeeded=True)
        await c.execute(
            text(
                "UPDATE app.deliveries SET status='sent',provider_message_id=:p,sent_at=now(),attempts=attempts+1,error_code=NULL WHERE institute_id=:i AND id=:id"
            ),
            {"p": provider_id, "i": w["institute_id"], "id": d["id"]},
        )
        await c.execute(
            text(
                "UPDATE app.jobs SET state='succeeded',stage='provider_accepted' WHERE institute_id=:i AND id=:id"
            ),
            {"i": w["institute_id"], "id": identifier},
        )
        return {
            "state": "succeeded",
            "delivery_status": "sent",
            "meaning": "Provider accepted; inbox delivery is not verified.",
        }


def install(app, engine, settings, principal, storage, auth):
    User = Annotated[object, Depends(principal)]
    Institute = Annotated[UUID, Header(alias="X-Institute-ID")]
    Key = Annotated[str, Header(alias="Idempotency-Key", min_length=1, max_length=128)]

    async def faculty(c, user, institute):
        if not (await roles(c, user, institute)) & {"teacher", "admin"}:
            raise APIError(403, "TEACHER_REQUIRED", "Faculty access is required.")

    async def owned_import(c, user, institute, identifier, lock=False):
        await faculty(c, user, institute)
        r = await one(
            c,
            "SELECT * FROM app.timetable_imports WHERE institute_id=:i AND id=:id"
            + (" FOR UPDATE" if lock else ""),
            {"i": institute, "id": identifier},
        )
        if not r or r["uploaded_by"] != user:
            raise APIError(404, "NOT_FOUND", "Timetable import not found.")
        return r

    @app.get("/v1/rooms")
    async def rooms(user: User, institute_id: Institute):
        async with transaction(engine, user.user_id, institute_id) as c:
            await faculty(c, user.user_id, institute_id)
            return {
                "items": [
                    dict(x)
                    for x in await many(
                        c,
                        "SELECT id,code,name,capacity FROM app.rooms WHERE institute_id=:i ORDER BY code LIMIT 200",
                        {"i": institute_id},
                    )
                ]
            }

    @app.post("/v1/rooms", status_code=201)
    async def room_create(
        body: RoomCreate, request: Request, user: User, institute_id: Institute, key: Key
    ):
        async with transaction(engine, user.user_id, institute_id) as c:
            await faculty(c, user.user_id, institute_id)
            route = request.url.path
            cached, fp = await idempotent(
                c, user.user_id, institute_id, route, key, body.model_dump()
            )
            if cached:
                return cached
            row = dict(
                await one(
                    c,
                    "INSERT INTO app.rooms(institute_id,code,name,capacity) VALUES(:i,:code,:name,:n) RETURNING id,code,name,capacity",
                    {"i": institute_id, "code": body.code, "name": body.name, "n": body.capacity},
                )
            )
            await remember(c, user.user_id, institute_id, route, key, fp, row)
            return row

    @app.post("/v1/media-reservations", status_code=201)
    async def reserve(
        body: Reservation, request: Request, user: User, institute_id: Institute, key: Key
    ):
        async with transaction(engine, user.user_id, institute_id) as c:
            await faculty(c, user.user_id, institute_id)
            route = request.url.path
            cached, fp = await idempotent(
                c, user.user_id, institute_id, route, key, body.model_dump()
            )
            if cached:
                return cached
            row = dict(
                await one(
                    c,
                    """INSERT INTO app.media_assets(institute_id,owner_user_id,purpose,bucket,object_key,mime_type,expected_bytes)
            VALUES(:i,:u,'timetable',:bucket,:key,'text/csv',:n) RETURNING id,reservation_expires_at""",
                    {
                        "i": institute_id,
                        "u": user.user_id,
                        "bucket": settings.documents_bucket,
                        "key": "timetable/" + uuid4().hex + ".csv",
                        "n": body.expected_bytes,
                    },
                )
            )
            await remember(c, user.user_id, institute_id, route, key, fp, row)
            return row

    @app.post("/v1/media-reservations/{identifier}/upload-grant")
    async def grant(identifier: UUID, user: User, institute_id: Institute):
        async with transaction(engine, user.user_id, institute_id) as c:
            await faculty(c, user.user_id, institute_id)
            a = await one(
                c,
                "SELECT * FROM app.media_assets WHERE institute_id=:i AND id=:id AND owner_user_id=:u AND purpose='timetable' FOR UPDATE",
                {"i": institute_id, "id": identifier, "u": user.user_id},
            )
            if not a:
                raise APIError(404, "NOT_FOUND", "Reservation not found.")
            if a["status"] != "reserved" or a["reservation_expires_at"] <= bio.now():
                raise APIError(409, "UPLOAD_EXPIRED", "Upload reservation expired.")
            await c.execute(
                text(
                    "UPDATE app.media_assets SET grant_expires_at=now()+interval '2 hours' WHERE institute_id=:i AND id=:id"
                ),
                {"i": institute_id, "id": identifier},
            )
        return await storage.upload(dict(a))

    @app.post("/v1/timetable-imports", status_code=202)
    async def importing(
        body: ImportCreate, request: Request, user: User, institute_id: Institute, key: Key
    ):
        route = request.url.path
        async with transaction(engine, user.user_id, institute_id) as c:
            await faculty(c, user.user_id, institute_id)
            a = await one(
                c,
                "SELECT * FROM app.media_assets WHERE institute_id=:i AND id=:id AND owner_user_id=:u AND purpose='timetable'",
                {"i": institute_id, "id": body.asset_id, "u": user.user_id},
            )
            if not a:
                raise APIError(404, "NOT_FOUND", "Reservation not found.")
            cached, _ = await idempotent(
                c, user.user_id, institute_id, route, key, body.model_dump()
            )
            if cached:
                return cached
        info = await storage.info(dict(a))
        async with transaction(engine, user.user_id, institute_id) as c:
            cached, fp = await idempotent(
                c, user.user_id, institute_id, route, key, body.model_dump()
            )
            if cached:
                return cached
            a = await one(
                c,
                "SELECT * FROM app.media_assets WHERE institute_id=:i AND id=:id FOR UPDATE",
                {"i": institute_id, "id": body.asset_id},
            )
            term = await one(
                c,
                "SELECT * FROM app.terms WHERE institute_id=:i AND id=:id",
                {"i": institute_id, "id": body.term_id},
            )
            if not term or term["schedule_revision"] != body.base_revision:
                raise APIError(409, "SCHEDULE_CHANGED", "Refresh the term schedule revision.")
            if a["status"] != "reserved" or a["reservation_expires_at"] <= bio.now():
                raise APIError(409, "UPLOAD_EXPIRED", "Upload reservation expired.")
            if (
                info["size"] != body.byte_size
                or a["expected_bytes"] != body.byte_size
                or info["mime_type"].split(";")[0] != "text/csv"
            ):
                raise APIError(409, "MEDIA_MISMATCH", "CSV metadata differs from its reservation.")
            await c.execute(
                text(
                    "UPDATE app.media_assets SET status='uploaded',byte_size=:n,sha256=:h WHERE institute_id=:i AND id=:id"
                ),
                {"n": body.byte_size, "h": body.sha256, "i": institute_id, "id": a["id"]},
            )
            imp = await one(
                c,
                "INSERT INTO app.timetable_imports(institute_id,term_id,asset_id,uploaded_by,base_revision,source_hash) VALUES(:i,:t,:a,:u,:v,:h) RETURNING id",
                {
                    "i": institute_id,
                    "t": term["id"],
                    "a": a["id"],
                    "u": user.user_id,
                    "v": body.base_revision,
                    "h": body.sha256,
                },
            )
            j = await one(
                c,
                "INSERT INTO app.jobs(institute_id,kind,timetable_import_id,dedup_key) VALUES(:i,'timetable',:id,:key) RETURNING id",
                {"i": institute_id, "id": imp["id"], "key": "timetable:" + str(imp["id"])},
            )
            result = {
                "resource_id": str(imp["id"]),
                "job_id": str(j["id"]),
                "state": "queued",
                "status_url": f"/v1/timetable-imports/{imp['id']}",
            }
            await remember(c, user.user_id, institute_id, route, key, fp, result, 202)
            return result

    @app.get("/v1/timetable-imports/{identifier}")
    async def import_status(identifier: UUID, user: User, institute_id: Institute):
        async with transaction(engine, user.user_id, institute_id) as c:
            return dict(await owned_import(c, user.user_id, institute_id, identifier))

    @app.get("/v1/terms/{identifier}/schedule")
    async def term_status(identifier: UUID, user: User, institute_id: Institute):
        async with transaction(engine, user.user_id, institute_id) as c:
            await faculty(c, user.user_id, institute_id)
            term = await one(
                c,
                "SELECT id,code,schedule_revision,starts_on,ends_on FROM app.terms WHERE institute_id=:i AND id=:id",
                {"i": institute_id, "id": identifier},
            )
            if not term:
                raise APIError(404, "NOT_FOUND", "Term not found.")
            return dict(term)

    @app.post("/v1/timetable-imports/{identifier}/commit")
    async def commit_import(
        identifier: UUID,
        body: ImportCommit,
        request: Request,
        user: User,
        institute_id: Institute,
        key: Key,
    ):
        async with transaction(engine, user.user_id, institute_id) as c:
            imp = await owned_import(c, user.user_id, institute_id, identifier)
            # Institute-wide timetable lock also serializes concurrent term imports using the same rooms/faculty.
            await c.execute(
                text("SELECT pg_advisory_xact_lock(hashtextextended(:x,0))"),
                {"x": "schedule:" + str(institute_id)},
            )
            term = await one(
                c,
                "SELECT * FROM app.terms WHERE institute_id=:i AND id=:id FOR UPDATE",
                {"i": institute_id, "id": imp["term_id"]},
            )
            imp = await owned_import(c, user.user_id, institute_id, identifier, lock=True)
            route = request.url.path
            cached, fp = await idempotent(
                c, user.user_id, institute_id, route, key, body.model_dump()
            )
            if cached:
                return cached
            if (
                imp["status"] != "ready"
                or imp["preview_hash"] != body.preview_hash
                or imp["base_revision"] != body.expected_revision
                or term["schedule_revision"] != body.expected_revision
            ):
                raise APIError(
                    409,
                    "SCHEDULE_CHANGED",
                    "Preview or term revision changed. Validate a new import.",
                )
            if not term["starts_on"] <= body.materialize_date <= term["ends_on"]:
                raise APIError(422, "DATE_OUTSIDE_TERM", "Choose a day inside this term.")
            rows = await normalized_rows(
                c,
                institute_id,
                imp["term_id"],
                user.user_id,
                [{k: r[k] for k in CSV_COLUMNS} for r in imp["preview_json"]["rows"]],
            )
            for row in rows:
                old = await one(
                    c,
                    "SELECT offering_id FROM app.schedule_series WHERE institute_id=:i AND term_id=:t AND entry_key=:k",
                    {"i": institute_id, "t": imp["term_id"], "k": row["entry_key"]},
                )
                if old:
                    await teacher_access(c, user.user_id, institute_id, old["offering_id"])
                await one(
                    c,
                    """INSERT INTO app.schedule_series(institute_id,term_id,offering_id,teacher_id,room_id,entry_key,weekday,local_start,local_end,effective_from,effective_until,timezone)
                VALUES(:i,:term,:o,:teacher,:room,:key,:day,:start,:end,:first,:last,'Asia/Kolkata')
                ON CONFLICT(institute_id,term_id,entry_key) DO UPDATE SET offering_id=excluded.offering_id,teacher_id=excluded.teacher_id,room_id=excluded.room_id,weekday=excluded.weekday,local_start=excluded.local_start,local_end=excluded.local_end,effective_from=excluded.effective_from,effective_until=excluded.effective_until,revision=app.schedule_series.revision+1 RETURNING id""",
                    {
                        "i": institute_id,
                        "term": imp["term_id"],
                        "o": UUID(row["offering_id"]),
                        "teacher": UUID(row["teacher_id"]),
                        "room": UUID(row["room_id"]),
                        "key": row["entry_key"],
                        "day": row["weekday_index"],
                        "start": time.fromisoformat(row["start_time"]),
                        "end": time.fromisoformat(row["end_time"]),
                        "first": date.fromisoformat(row["effective_from"]),
                        "last": date.fromisoformat(row["effective_until"]),
                    },
                )
            # Materialize all current authorized series for this day, including omitted retained rows.
            current = await many(
                c,
                "SELECT * FROM app.schedule_series WHERE institute_id=:i AND term_id=:t AND status='active' AND weekday=:w AND effective_from<=:d AND effective_until>=:d",
                {
                    "i": institute_id,
                    "t": imp["term_id"],
                    "w": body.materialize_date.weekday(),
                    "d": body.materialize_date,
                },
            )
            count = 0
            for x in current:
                permitted = await one(
                    c,
                    "SELECT app.faculty_can_teach(:a,:o) AS ok",
                    {"a": user.user_id, "o": x["offering_id"]},
                )
                if not permitted["ok"]:
                    continue
                start = datetime.combine(
                    body.materialize_date, x["local_start"], ZoneInfo(x["timezone"])
                )
                end = datetime.combine(
                    body.materialize_date, x["local_end"], ZoneInfo(x["timezone"])
                )
                occurrence = f"{x['id']}:{body.materialize_date.isoformat()}"
                old = await one(
                    c,
                    "SELECT * FROM app.sessions WHERE institute_id=:i AND occurrence_key=:k FOR UPDATE",
                    {"i": institute_id, "k": occurrence},
                )
                if old and old["status"] != "scheduled":
                    if (
                        old["starts_at"] != start
                        or old["ends_at"] != end
                        or old["teacher_id"] != x["teacher_id"]
                        or old["room_id"] != x["room_id"]
                    ):
                        raise APIError(
                            409,
                            "OPENED_SESSION",
                            "An opened session cannot be replaced by this import.",
                        )
                    continue
                conflict = await one(
                    c,
                    """SELECT id FROM app.sessions WHERE institute_id=:i AND occurrence_key<>:key AND status<>'cancelled' AND starts_at<:end AND ends_at>:start
                AND (teacher_id=:teacher OR offering_id=:o OR room_id=:room)""",
                    {
                        "i": institute_id,
                        "key": occurrence,
                        "end": end,
                        "start": start,
                        "teacher": x["teacher_id"],
                        "o": x["offering_id"],
                        "room": x["room_id"],
                    },
                )
                if conflict:
                    raise APIError(
                        409,
                        "TIMETABLE_OVERLAP",
                        "A scheduled session conflicts with the selected day.",
                    )
                room = await one(
                    c,
                    "SELECT code FROM app.rooms WHERE institute_id=:i AND id=:id",
                    {"i": institute_id, "id": x["room_id"]},
                )
                await c.execute(
                    text("""INSERT INTO app.sessions(institute_id,offering_id,teacher_id,starts_at,ends_at,room_id,room_label,series_id,occurrence_key)
                VALUES(:i,:o,:teacher,:start,:end,:room,:label,:series,:key) ON CONFLICT(institute_id,occurrence_key) DO UPDATE SET starts_at=excluded.starts_at,ends_at=excluded.ends_at,teacher_id=excluded.teacher_id,room_id=excluded.room_id,room_label=excluded.room_label,offering_id=excluded.offering_id,version=app.sessions.version+1 WHERE app.sessions.status='scheduled'"""),
                    {
                        "i": institute_id,
                        "o": x["offering_id"],
                        "teacher": x["teacher_id"],
                        "start": start,
                        "end": end,
                        "room": x["room_id"],
                        "label": room["code"],
                        "series": x["id"],
                        "key": occurrence,
                    },
                )
                count += 1
            if count == 0:
                raise APIError(
                    422,
                    "NO_SESSION_ON_DATE",
                    "No authorized timetable entry occurs on the selected date. Choose a matching weekday within its effective dates.",
                )
            await c.execute(
                text(
                    "UPDATE app.terms SET schedule_revision=schedule_revision+1,version=version+1 WHERE institute_id=:i AND id=:id"
                ),
                {"i": institute_id, "id": imp["term_id"]},
            )
            await c.execute(
                text(
                    "UPDATE app.timetable_imports SET status='committed',version=version+1 WHERE institute_id=:i AND id=:id"
                ),
                {"i": institute_id, "id": identifier},
            )
            result = {
                "status": "committed",
                "schedule_revision": body.expected_revision + 1,
                "sessions_materialized": count,
            }
            await remember(c, user.user_id, institute_id, route, key, fp, result, 200)
            await audit(
                c,
                user.user_id,
                institute_id,
                "timetable.committed",
                "timetable_import",
                identifier,
                request.state.request_id,
            )
            return result

    async def report_access(c, user, institute, identifier):
        r = await one(
            c,
            "SELECT * FROM app.reports WHERE institute_id=:i AND id=:id",
            {"i": institute, "id": identifier},
        )
        if not r:
            raise APIError(404, "NOT_FOUND", "Report not found.")
        await session(c, user, institute, r["session_id"])
        return r

    @app.get("/v1/sessions/{identifier}/reports")
    async def report_list(identifier: UUID, user: User, institute_id: Institute):
        async with transaction(engine, user.user_id, institute_id) as c:
            await session(c, user.user_id, institute_id, identifier)
            return {
                "items": [
                    dict(x)
                    for x in await many(
                        c,
                        "SELECT id,kind,source_version,status,created_at,expires_at FROM app.reports WHERE institute_id=:i AND session_id=:id ORDER BY created_at DESC LIMIT 100",
                        {"i": institute_id, "id": identifier},
                    )
                ]
            }

    @app.get("/v1/reports/{identifier}")
    async def report_status(identifier: UUID, user: User, institute_id: Institute):
        async with transaction(engine, user.user_id, institute_id) as c:
            r = await report_access(c, user.user_id, institute_id, identifier)
            deliveries = [
                dict(d)
                for d in await many(
                    c,
                    "SELECT id,status,error_code,sent_at FROM app.deliveries WHERE institute_id=:i AND report_id=:id",
                    {"i": institute_id, "id": identifier},
                )
            ]
            return {
                k: r[k]
                for k in ("id", "session_id", "kind", "source_version", "status", "expires_at")
            } | {
                "deliveries": deliveries,
                "email_configured": bool(
                    settings.resend_api_key.get_secret_value() and settings.resend_from
                ),
            }

    @app.get("/v1/reports/{identifier}/download")
    async def download(
        identifier: UUID, user: User, institute_id: Institute, format: Literal["csv", "pdf"] = "pdf"
    ):
        async with transaction(engine, user.user_id, institute_id) as c:
            r = await report_access(c, user.user_id, institute_id, identifier)
            if r["status"] != "ready" or r["expires_at"] <= bio.now():
                raise APIError(409, "REPORT_UNAVAILABLE", "Report is not ready or has expired.")
            asset = dict(
                await one(
                    c,
                    "SELECT * FROM app.media_assets WHERE institute_id=:i AND id=:id",
                    {"i": institute_id, "id": r[format + "_asset_id"]},
                )
            )
        return {"url": await storage.download(asset), "expires_in": 60}

    @app.post("/v1/reports/{identifier}/retry", status_code=202)
    async def retry_report(
        identifier: UUID, request: Request, user: User, institute_id: Institute, key: Key
    ):
        async with transaction(engine, user.user_id, institute_id) as c:
            report = await report_access(c, user.user_id, institute_id, identifier)
            route = request.url.path
            cached, fp = await idempotent(c, user.user_id, institute_id, route, key, {})
            if cached:
                return cached
            job = await one(
                c,
                "SELECT id,state FROM app.jobs WHERE institute_id=:i AND report_id=:r FOR UPDATE",
                {"i": institute_id, "r": identifier},
            )
            if (
                not job
                or job["state"] != "failed"
                or report["status"] != "failed"
                or report["expires_at"] <= bio.now()
            ):
                raise APIError(
                    409, "REPORT_NOT_RETRYABLE", "Refresh report status before retrying."
                )
            await c.execute(
                text("""UPDATE app.jobs SET state='queued',stage='queued',attempts=0,
                available_at=now(),lease_epoch=lease_epoch+1,error_code=NULL
                WHERE institute_id=:i AND id=:id"""),
                {"i": institute_id, "id": job["id"]},
            )
            await c.execute(
                text("UPDATE app.reports SET status='queued' WHERE institute_id=:i AND id=:id"),
                {"i": institute_id, "id": identifier},
            )
            result = {"state": "queued", "job_id": str(job["id"])}
            await remember(c, user.user_id, institute_id, route, key, fp, result, 202)
            return result

    @app.post("/v1/reports/{identifier}/deliveries", status_code=202)
    async def delivery(
        identifier: UUID, request: Request, user: User, institute_id: Institute, key: Key
    ):
        if not settings.resend_api_key.get_secret_value() or not settings.resend_from:
            raise APIError(
                503, "EMAIL_NOT_CONFIGURED", "Email is not configured. Download the report instead."
            )
        email = await auth.confirmed_email(user)
        async with transaction(engine, user.user_id, institute_id) as c:
            r = await report_access(c, user.user_id, institute_id, identifier)
            s = await session(c, user.user_id, institute_id, r["session_id"])
            faculty_row = await one(
                c,
                "SELECT auth_user_id,official_email FROM app.teachers WHERE institute_id=:i AND id=:t AND status='approved'",
                {"i": institute_id, "t": s["teacher_id"]},
            )
            if (
                r["status"] != "ready"
                or r["kind"] != "final"
                or faculty_row["auth_user_id"] != user.user_id
                or faculty_row["official_email"] != email
            ):
                raise APIError(
                    403,
                    "RECIPIENT_UNVERIFIED",
                    "Only the session faculty with matching verified official email can request delivery.",
                )
            route = request.url.path
            cached, fp = await idempotent(c, user.user_id, institute_id, route, key, {})
            if cached:
                return cached
            d = await one(
                c,
                """INSERT INTO app.deliveries(institute_id,report_id,recipient_user_id,recipient_email,dedup_key)
            VALUES(:i,:r,:u,:email,:key) ON CONFLICT(institute_id,dedup_key) DO UPDATE SET dedup_key=excluded.dedup_key RETURNING id,status""",
                {
                    "i": institute_id,
                    "r": identifier,
                    "u": user.user_id,
                    "email": email,
                    "key": f"{identifier}:{user.user_id}",
                },
            )
            j = await one(
                c,
                "INSERT INTO app.jobs(institute_id,kind,delivery_id,dedup_key) VALUES(:i,'delivery',:d,:key) ON CONFLICT(institute_id,dedup_key) DO UPDATE SET dedup_key=excluded.dedup_key RETURNING id,state",
                {"i": institute_id, "d": d["id"], "key": "delivery:" + str(d["id"])},
            )
            if d["status"] == "failed":
                await c.execute(
                    text(
                        "UPDATE app.jobs SET state='queued',stage='queued',attempts=0,available_at=now(),lease_epoch=lease_epoch+1 WHERE institute_id=:i AND id=:id AND state='failed'"
                    ),
                    {"i": institute_id, "id": j["id"]},
                )
                await c.execute(
                    text(
                        "UPDATE app.deliveries SET status='queued',error_code=NULL WHERE institute_id=:i AND id=:id"
                    ),
                    {"i": institute_id, "id": d["id"]},
                )
            result = {
                "job_id": str(j["id"]),
                "resource_id": str(d["id"]),
                "state": j["state"],
                "status_url": f"/v1/reports/{identifier}",
            }
            await remember(c, user.user_id, institute_id, route, key, fp, result, 202)
            return result

    @app.post("/internal/v1/jobs/{identifier}/deliver")
    async def worker_delivery(
        identifier: UUID, body: Epoch, authorization: Annotated[str, Header(alias="Authorization")]
    ):
        if not authorization.startswith("Bearer "):
            raise APIError(401, "WORKER_REQUIRED", "Worker credential required.")
        return await deliver(engine, authorization[7:], identifier, body.epoch, settings)
