"""Teacher-controlled sessions, frozen rosters and immutable attendance publications."""

import json
from datetime import datetime, timedelta
from typing import Annotated, Literal
from uuid import UUID, uuid4

from fastapi import Depends, Header, Query, Request
from fastapi.encoders import jsonable_encoder
from pydantic import Field, field_validator, model_validator
from sqlalchemy import text

from . import biometrics as bio
from . import services
from .db import many, one, transaction
from .errors import APIError
from .schemas import Strict
from .security import audit, check_cursor, expected_version, idempotent, page, teacher_access
from .security import remember as remember_effect


async def remember(conn, actor, institute, route, key, fp, result, status=201):
    await remember_effect(conn, actor, institute, route, key, fp, jsonable_encoder(result), status)


class SessionCreate(Strict):
    offering_id: UUID
    starts_at: datetime
    ends_at: datetime
    room_label: str = Field(default="", max_length=100)

    @model_validator(mode="after")
    def times(self):
        if (
            self.starts_at.tzinfo is None
            or self.ends_at.tzinfo is None
            or not timedelta(0) < self.ends_at - self.starts_at <= timedelta(hours=12)
        ):
            raise ValueError("Use timezone-aware dates and a duration up to 12 hours.")
        return self


class Decision(Strict):
    student_id: UUID
    status: Literal["present", "absent"]
    reason: str | None = Field(default=None, max_length=500)


class Review(Strict):
    decisions: list[Decision] = Field(max_length=500)
    acknowledge_unassessed: bool = Field(default=False, deprecated=True)

    @model_validator(mode="after")
    def unique(self):
        if len({x.student_id for x in self.decisions}) != len(self.decisions):
            raise ValueError("Duplicate student decision.")
        return self


class Correction(Decision):
    reason: str = Field(min_length=1, max_length=500)
    publication_revision: int = Field(gt=0)


class Cancel(Strict):
    reason: str = Field(min_length=1, max_length=500)


class DisputeCreate(Strict):
    reason: str = Field(min_length=5, max_length=1000)

    @field_validator("reason")
    @classmethod
    def meaningful_reason(cls, value: str) -> str:
        value = value.strip()
        if len(value) < 5:
            raise ValueError("Enter at least 5 non-space characters.")
        return value


class DisputeResolution(Strict):
    decision: Literal["accepted", "rejected"]
    reason: str = Field(min_length=3, max_length=1000)

    @field_validator("reason")
    @classmethod
    def meaningful_reason(cls, value: str) -> str:
        value = value.strip()
        if len(value) < 3:
            raise ValueError("Enter at least 3 non-space characters.")
        return value


class CaptureCreate(Strict):
    source_type: Literal["webcam", "phone"]
    recorded_at: datetime
    mime_type: Literal["video/webm", "video/mp4"]
    expected_bytes: int = Field(gt=0, le=26214400)

    @model_validator(mode="after")
    def aware(self):
        if self.recorded_at.tzinfo is None:
            raise ValueError("recorded_at must include timezone.")
        return self


async def session(conn, actor, institute, identifier, *, lock=False):
    row = await one(
        conn,
        "SELECT * FROM app.sessions WHERE institute_id=:i AND id=:id"
        + (" FOR UPDATE" if lock else ""),
        {"i": institute, "id": identifier},
    )
    if not row:
        raise APIError(404, "NOT_FOUND", "Session not found.")
    await teacher_access(conn, actor, institute, row["offering_id"])
    return row


def version_check(row, version):
    if row["version"] != version:
        raise APIError(409, "VERSION_CONFLICT", "Refresh the session before trying again.")


async def attendance(conn, institute, identifier):
    return [
        dict(x)
        for x in await many(
            conn,
            """SELECT a.*,r.name_snapshot AS official_name,r.enrollment_number_snapshot AS enrollment_number,r.recognition_eligible
    FROM app.attendance_records a JOIN app.session_roster r USING(institute_id,session_id,student_id)
    WHERE a.institute_id=:i AND a.session_id=:id ORDER BY r.enrollment_number_snapshot,r.student_id""",
            {"i": institute, "id": identifier},
        )
    ]


async def report_labels(conn, institute, s):
    academic = await one(
        conn,
        """SELECT i.name AS institute_name,c.code AS course_code,c.title AS course_title,
        t.code AS term_code,g.branch,g.semester,g.section
        FROM app.offerings o JOIN app.institutes i ON i.id=o.institute_id
        JOIN app.courses c ON c.institute_id=o.institute_id AND c.id=o.course_id
        JOIN app.terms t ON t.institute_id=o.institute_id AND t.id=o.term_id
        JOIN app.class_groups g ON g.institute_id=o.institute_id AND g.id=o.class_group_id
        WHERE o.institute_id=:i AND o.id=:o""",
        {"i": institute, "o": s["offering_id"]},
    )
    return {
        **dict(academic),
        "ends_at": s["ends_at"].isoformat(),
        "timezone": "Asia/Kolkata",
        "room": s["room_label"],
    }


FROZEN_ELIGIBILITY_JOINS = """
    JOIN app.template_sets t ON (t.institute_id,t.id,t.student_id)
        =(r.institute_id,r.template_set_id,r.student_id)
    JOIN app.enrollment_attempts a ON (a.institute_id,a.id)=(t.institute_id,t.attempt_id)
    JOIN app.consents c ON (c.institute_id,c.id)=(a.institute_id,a.consent_id)
    JOIN app.students s ON (s.institute_id,s.id)=(r.institute_id,r.student_id)
"""
FROZEN_ELIGIBILITY = """r.recognition_eligible AND t.status='active'
    AND c.withdrawn_at IS NULL AND s.template_epoch=r.template_epoch
    AND app.biometric_student_active(s.id)"""


async def eligible(conn, institute, student, set_id, epoch):
    return await one(
        conn,
        """SELECT t.* FROM app.template_sets t JOIN app.enrollment_attempts a ON a.institute_id=t.institute_id AND a.id=t.attempt_id
    JOIN app.consents c ON c.institute_id=a.institute_id AND c.id=a.consent_id
    JOIN app.students s ON s.institute_id=t.institute_id AND s.id=t.student_id
    WHERE t.institute_id=:i AND t.id=:t AND t.student_id=:s AND t.status='active' AND c.withdrawn_at IS NULL
    AND s.template_epoch=:e AND app.biometric_student_active(s.id)""",
        {"i": institute, "s": student, "t": set_id, "e": epoch},
    )


async def create_session(conn, actor, institute, body, key, request_id):
    await teacher_access(conn, actor, institute, body.offering_id)
    teacher = await one(
        conn,
        """SELECT t.id FROM app.teachers t JOIN app.offering_teachers ot ON ot.institute_id=t.institute_id AND ot.teacher_id=t.id
    WHERE t.institute_id=:i AND ot.offering_id=:o AND ot.status='active' AND t.status='approved' AND t.auth_user_id=:a""",
        {"i": institute, "o": body.offering_id, "a": actor},
    )
    if not teacher:
        raise APIError(403, "TEACHER_REQUIRED", "An assigned faculty identity is required.")
    route = "/v1/sessions"
    cached, fp = await idempotent(conn, actor, institute, route, key, body.model_dump())
    if cached:
        return cached
    row = dict(
        await one(
            conn,
            """INSERT INTO app.sessions(institute_id,offering_id,teacher_id,starts_at,ends_at,room_label,occurrence_key)
    VALUES(:i,:o,:t,:start,:end,:room,:key) RETURNING *""",
            {
                "i": institute,
                "o": body.offering_id,
                "t": teacher["id"],
                "start": body.starts_at,
                "end": body.ends_at,
                "room": body.room_label,
                "key": "manual:" + str(uuid4()),
            },
        )
    )
    await audit(conn, actor, institute, "session.created", "session", row["id"], request_id)
    await remember(conn, actor, institute, route, key, fp, row, 201)
    return row


async def open_session(conn, actor, institute, identifier, version, key, req):
    s = await session(conn, actor, institute, identifier, lock=True)
    route = f"/v1/sessions/{identifier}/open"
    cached, fp = await idempotent(conn, actor, institute, route, key, {"version": version})
    if cached:
        return cached
    version_check(s, version)
    if (
        s["status"] != "scheduled"
        or not s["starts_at"] - timedelta(minutes=5) <= bio.now() <= s["ends_at"]
    ):
        raise APIError(
            409, "SESSION_NOT_OPENABLE", "Open within 5 minutes of its start and before its end."
        )
    config = await one(
        conn,
        bio.CURRENT_RECOGNITION_PROFILE,
        {"i": institute},
    )
    if not config:
        raise APIError(409, "MODEL_UNAVAILABLE", "No approved model/profile is configured.")
    people = await many(
        conn,
        f"""WITH eligible_roster AS (
          INSERT INTO app.session_roster(
            institute_id,session_id,student_id,name_snapshot,enrollment_number_snapshot,
            template_set_id,template_epoch,recognition_eligible
          )
          SELECT e.institute_id,:session,s.id,s.official_name,s.enrollment_number,
                 face.id,s.template_epoch,true
          FROM app.course_enrollments e
          JOIN app.students s ON (s.institute_id,s.id)=(e.institute_id,e.student_id)
          CROSS JOIN (SELECT CAST(:model AS uuid) AS model,CAST(:profile AS uuid) AS profile) p
          CROSS JOIN LATERAL ({bio.COMPATIBLE_FACE_SET}) face
          WHERE e.institute_id=:i AND e.offering_id=:o AND e.status='active'
            AND e.effective_from<=now() AND (e.effective_until IS NULL OR e.effective_until>now())
            AND app.biometric_student_active(s.id)
          RETURNING institute_id,session_id,student_id,template_set_id,template_epoch
        ), marks AS (
          INSERT INTO app.attendance_records(institute_id,session_id,student_id)
          SELECT institute_id,session_id,student_id FROM eligible_roster
        )
        SELECT student_id,template_set_id,template_epoch FROM eligible_roster ORDER BY student_id""",
        {"i": institute, "o": s["offering_id"], "session": identifier, **config},
    )
    if not people:
        raise APIError(
            409,
            "NO_ATTENDANCE_ELIGIBLE",
            "Approve at least one student's face enrolment before opening attendance.",
        )
    frozen = [
        {
            "student": str(person["student_id"]),
            "template": str(person["template_set_id"]),
            "epoch": person["template_epoch"],
        }
        for person in people
    ]
    row = dict(
        await one(
            conn,
            """UPDATE app.sessions SET status='open',roster_hash=:h,model_release_id=:m,recognition_profile_id=:p,version=version+1
    WHERE institute_id=:i AND id=:id RETURNING *""",
            {
                "i": institute,
                "id": identifier,
                "h": bio.digest(frozen),
                "m": config["model"],
                "p": config["profile"],
            },
        )
    )
    await audit(conn, actor, institute, "session.opened", "session", identifier, req)
    await remember(conn, actor, institute, route, key, fp, row, 200)
    return row


async def apply_decisions(conn, actor, institute, identifier, decisions):
    if not decisions:
        return
    rows = await many(
        conn,
        """UPDATE app.attendance_records m
        SET status=d.status,source='teacher',manual_lock=true,reason=d.reason,
            modified_by=:a,version=m.version+1
        FROM jsonb_to_recordset(CAST(:decisions AS jsonb)) AS d(student_id uuid,status text,reason text)
        WHERE m.institute_id=:i AND m.session_id=:id AND m.student_id=d.student_id
        RETURNING m.student_id""",
        {
            "a": actor,
            "i": institute,
            "id": identifier,
            "decisions": json.dumps([d.model_dump(mode="json") for d in decisions]),
        },
    )
    if len(rows) != len(decisions):
        raise APIError(422, "NOT_ON_ROSTER", "A student is not on this session roster.")


async def can_publish(conn, actor, institute, offering):
    permission = await one(
        conn,
        """SELECT ot.id FROM app.offering_teachers ot JOIN app.teachers t ON t.institute_id=ot.institute_id AND t.id=ot.teacher_id
    WHERE ot.institute_id=:i AND ot.offering_id=:o AND ot.status='active' AND ot.can_finalize AND t.auth_user_id=:a AND t.status='approved'""",
        {"i": institute, "o": offering, "a": actor},
    )
    if not permission:
        raise APIError(
            403, "PUBLICATION_FORBIDDEN", "This teaching assignment cannot publish attendance."
        )


async def recognition_pending(conn, institute, session_id):
    return bool(
        await one(
            conn,
            """SELECT j.id FROM app.jobs j JOIN app.captures cap
           ON cap.institute_id=j.institute_id AND cap.id=j.capture_id
           WHERE cap.institute_id=:i AND cap.session_id=:id
           AND j.state IN ('queued','leased','running','retry_wait') LIMIT 1""",
            {"i": institute, "id": session_id},
        )
    )


async def publish(conn, actor, institute, s, reason=None):
    await can_publish(conn, actor, institute, s["offering_id"])
    rows = await attendance(conn, institute, s["id"])
    if any(x["status"] not in ("present", "absent") for x in rows):
        raise APIError(
            409,
            "REVIEW_REQUIRED",
            "Choose Present or Absent for every student before publishing.",
        )
    snapshot = {
        **(await report_labels(conn, institute, s)),
        "session_id": str(s["id"]),
        "offering_id": str(s["offering_id"]),
        "starts_at": s["starts_at"].isoformat(),
        "policy_version": "session-v1",
        "incomplete": False,
        "records": rows,
    }
    revision = s["attendance_revision"] + 1
    publication = dict(
        await one(
            conn,
            """INSERT INTO app.publications(institute_id,session_id,revision,snapshot_json,snapshot_hash,published_by,reason)
    VALUES(:i,:id,:v,CAST(:s AS jsonb),:h,:a,:r) RETURNING id,revision,published_at""",
            {
                "i": institute,
                "id": s["id"],
                "v": revision,
                "s": json.dumps(snapshot, default=str),
                "h": bio.digest(snapshot),
                "a": actor,
                "r": reason,
            },
        )
    )
    await conn.execute(
        text(
            "UPDATE app.sessions SET status='finalized',attendance_revision=:r,version=version+1 WHERE institute_id=:i AND id=:id"
        ),
        {"r": revision, "i": institute, "id": s["id"]},
    )
    from .documents import enqueue_report

    await enqueue_report(conn, actor, institute, snapshot, s["id"], revision, publication["id"])
    return publication


async def still_absent(conn, institute, dispute):
    """Whether the disputing student is still Absent in the current publication.

    Another query on the same session may have been accepted since, publishing a
    newer revision; that does not change this student's disputed result."""
    if dispute["attendance_revision"] == dispute["source_revision"]:
        return True
    current = await one(
        conn,
        "SELECT snapshot_json FROM app.publications WHERE institute_id=:i AND session_id=:s AND revision=:r",
        {"i": institute, "s": dispute["session_id"], "r": dispute["attendance_revision"]},
    )
    mine = current and next(
        (
            x
            for x in current["snapshot_json"]["records"]
            if x["student_id"] == str(dispute["student_id"])
        ),
        None,
    )
    return bool(mine) and mine["status"] == "absent"


def install(app, engine, settings, principal, storage):
    User = Annotated[object, Depends(principal)]
    Institute = Annotated[UUID, Header(alias="X-Institute-ID")]
    Key = Annotated[str, Header(alias="Idempotency-Key", min_length=1, max_length=128)]
    Version = Annotated[str, Header(alias="If-Match")]

    @app.post("/v1/sessions", status_code=201)
    async def create(
        body: SessionCreate, request: Request, user: User, institute_id: Institute, key: Key
    ):
        async with transaction(engine, user.user_id, institute_id) as c:
            return await create_session(
                c, user.user_id, institute_id, body, key, request.state.request_id
            )

    @app.get("/v1/sessions")
    async def listing(
        offering_id: UUID,
        user: User,
        institute_id: Institute,
        cursor: UUID | None = None,
        limit: Annotated[int, Query(ge=1, le=200)] = 50,
    ):
        async with transaction(engine, user.user_id, institute_id) as c:
            await teacher_access(c, user.user_id, institute_id, offering_id)
            await check_cursor(
                c,
                cursor,
                """SELECT 1 FROM app.sessions
                WHERE institute_id=:i AND offering_id=:o AND id=CAST(:cur AS uuid)""",
                {"i": institute_id, "o": offering_id},
            )
            return page(
                await many(
                    c,
                    """SELECT * FROM app.sessions WHERE institute_id=:i AND offering_id=:o
                    AND (CAST(:cur AS uuid) IS NULL OR (starts_at,id)<(SELECT starts_at,id FROM app.sessions
                      WHERE institute_id=:i AND id=CAST(:cur AS uuid)))
                    ORDER BY starts_at DESC,id DESC LIMIT :n""",
                    {
                        "i": institute_id,
                        "o": offering_id,
                        "cur": str(cursor) if cursor else None,
                        "n": limit + 1,
                    },
                ),
                limit,
            )

    @app.get("/v1/sessions/{identifier}")
    async def detail(identifier: UUID, user: User, institute_id: Institute):
        async with transaction(engine, user.user_id, institute_id) as c:
            return dict(await session(c, user.user_id, institute_id, identifier))

    @app.post("/v1/sessions/{identifier}/open")
    async def opening(
        identifier: UUID,
        request: Request,
        user: User,
        institute_id: Institute,
        key: Key,
        version: Version,
    ):
        async with transaction(engine, user.user_id, institute_id) as c:
            return await open_session(
                c,
                user.user_id,
                institute_id,
                identifier,
                expected_version(version),
                key,
                request.state.request_id,
            )

    @app.post("/v1/sessions/{identifier}/close")
    async def closing(
        identifier: UUID,
        request: Request,
        user: User,
        institute_id: Institute,
        key: Key,
        version: Version,
    ):
        async with transaction(engine, user.user_id, institute_id) as c:
            s = await session(c, user.user_id, institute_id, identifier, lock=True)
            route = f"/v1/sessions/{identifier}/close"
            cached, fp = await idempotent(
                c, user.user_id, institute_id, route, key, {"version": version}
            )
            if cached:
                return cached
            version_check(s, expected_version(version))
            if s["status"] != "open":
                raise APIError(409, "SESSION_STATE", "Only open sessions can close.")
            rows = await attendance(c, institute_id, identifier)
            state = (
                "review_required" if any(x["status"] != "unassessed" for x in rows) else "no_data"
            )
            result = dict(
                await one(
                    c,
                    "UPDATE app.sessions SET status=:s,version=version+1 WHERE institute_id=:i AND id=:id RETURNING *",
                    {"s": state, "i": institute_id, "id": identifier},
                )
            )
            from .documents import enqueue_report

            snapshot = {
                **(await report_labels(c, institute_id, s)),
                "session_id": str(identifier),
                "offering_id": str(s["offering_id"]),
                "starts_at": s["starts_at"].isoformat(),
                "policy_version": "session-v1",
                "records": rows,
                "incomplete": any(
                    x["status"] in ("unassessed", "proposed_present", "proposed_absent")
                    for x in rows
                ),
            }
            await enqueue_report(
                c, user.user_id, institute_id, snapshot, identifier, result["version"]
            )
            await remember(c, user.user_id, institute_id, route, key, fp, result, 200)
            await audit(
                c,
                user.user_id,
                institute_id,
                "session.closed",
                "session",
                identifier,
                request.state.request_id,
            )
            return result

    @app.post("/v1/sessions/{identifier}/cancel")
    async def cancelling(
        identifier: UUID,
        body: Cancel,
        request: Request,
        user: User,
        institute_id: Institute,
        key: Key,
        version: Version,
    ):
        async with transaction(engine, user.user_id, institute_id) as c:
            s = await session(c, user.user_id, institute_id, identifier, lock=True)
            route = f"/v1/sessions/{identifier}/cancel"
            cached, fp = await idempotent(
                c,
                user.user_id,
                institute_id,
                route,
                key,
                {"body": body.model_dump(), "version": version},
            )
            if cached:
                return cached
            version_check(s, expected_version(version))
            if s["status"] not in ("scheduled", "open"):
                raise APIError(409, "SESSION_STATE", "This session cannot be cancelled.")
            await c.execute(
                text(
                    "UPDATE app.sessions SET status='cancelled',version=version+1 WHERE institute_id=:i AND id=:id"
                ),
                {"i": institute_id, "id": identifier},
            )
            await c.execute(
                text(
                    "UPDATE app.jobs j SET state='cancelled' FROM app.captures cap WHERE j.institute_id=:i AND cap.institute_id=j.institute_id AND cap.id=j.capture_id AND cap.session_id=:id AND j.state NOT IN ('succeeded','failed','cancelled')"
                ),
                {"i": institute_id, "id": identifier},
            )
            await c.execute(
                text(
                    "UPDATE app.captures SET status='cancelled',version=version+1 WHERE institute_id=:i AND session_id=:id AND status IN ('awaiting_upload','queued','processing')"
                ),
                {"i": institute_id, "id": identifier},
            )
            await c.execute(
                text(
                    "UPDATE app.media_assets m SET status='delete_pending' FROM app.captures cap WHERE m.institute_id=:i AND cap.institute_id=m.institute_id AND cap.asset_id=m.id AND cap.session_id=:id"
                ),
                {"i": institute_id, "id": identifier},
            )
            result = {"status": "cancelled"}
            await remember(c, user.user_id, institute_id, route, key, fp, result, 200)
            await audit(
                c,
                user.user_id,
                institute_id,
                "session.cancelled",
                "session",
                identifier,
                request.state.request_id,
            )
            return result

    @app.get("/v1/sessions/{identifier}/attendance")
    async def records(
        identifier: UUID,
        user: User,
        institute_id: Institute,
        known_version: Annotated[int | None, Query(ge=1)] = None,
        known_processing: bool | None = None,
    ):
        async with transaction(engine, user.user_id, institute_id) as c:
            s = await session(c, user.user_id, institute_id, identifier)
            pending = await recognition_pending(c, institute_id, identifier)
            # While recognition is active, multiple clips may update marks and
            # capture state. Refresh the details until the queue has settled.
            if not pending and known_processing is False and known_version == s["version"]:
                return {"unchanged": True}
            return {
                "session": dict(s),
                "items": await attendance(c, institute_id, identifier),
                "processing_pending": pending,
            }

    @app.put("/v1/sessions/{identifier}/attendance-review")
    @app.post("/v1/sessions/{identifier}/finalize")
    async def review(
        identifier: UUID,
        body: Review,
        request: Request,
        user: User,
        institute_id: Institute,
        key: Key,
        version: Version,
    ):
        async with transaction(engine, user.user_id, institute_id) as c:
            s = await session(c, user.user_id, institute_id, identifier, lock=True)
            route = request.url.path
            cached, fp = await idempotent(
                c,
                user.user_id,
                institute_id,
                route,
                key,
                {"body": body.model_dump(), "version": version},
            )
            if cached:
                return cached
            version_check(s, expected_version(version))
            if s["status"] not in ("open", "closed", "review_required", "no_data"):
                raise APIError(409, "SESSION_STATE", "This session is not available for review.")
            finalize = route.endswith("/finalize")
            if finalize and s["status"] == "open":
                raise APIError(409, "SESSION_STATE", "Close the session before publishing.")
            if finalize and await recognition_pending(c, institute_id, identifier):
                raise APIError(
                    409, "PROCESSING_PENDING", "Wait for processing to finish before publishing."
                )
            await apply_decisions(c, user.user_id, institute_id, identifier, body.decisions)
            result = (
                await publish(c, user.user_id, institute_id, s)
                if finalize
                else dict(
                    await one(
                        c,
                        "UPDATE app.sessions SET version=version+1 WHERE institute_id=:i AND id=:id RETURNING *",
                        {"i": institute_id, "id": identifier},
                    )
                )
            )
            await audit(
                c,
                user.user_id,
                institute_id,
                "attendance.published" if finalize else "attendance.reviewed",
                "session",
                identifier,
                request.state.request_id,
            )
            await remember(c, user.user_id, institute_id, route, key, fp, result, 200)
            return result

    @app.post("/v1/sessions/{identifier}/corrections")
    async def correction(
        identifier: UUID,
        body: Correction,
        request: Request,
        user: User,
        institute_id: Institute,
        key: Key,
        version: Version,
    ):
        async with transaction(engine, user.user_id, institute_id) as c:
            s = await session(c, user.user_id, institute_id, identifier, lock=True)
            route = request.url.path
            cached, fp = await idempotent(
                c,
                user.user_id,
                institute_id,
                route,
                key,
                {"body": body.model_dump(), "version": version},
            )
            if cached:
                return cached
            version_check(s, expected_version(version))
            if s["status"] != "finalized" or s["attendance_revision"] != body.publication_revision:
                raise APIError(
                    409,
                    "PUBLICATION_CHANGED",
                    "Refresh the published session before correcting it.",
                )
            await apply_decisions(c, user.user_id, institute_id, identifier, [body])
            result = await publish(c, user.user_id, institute_id, s, body.reason)
            await audit(
                c,
                user.user_id,
                institute_id,
                "attendance.corrected",
                "session",
                identifier,
                request.state.request_id,
            )
            await remember(c, user.user_id, institute_id, route, key, fp, result, 200)
            return result

    @app.get("/v1/me/attendance")
    async def own(
        user: User,
        institute_id: Institute,
        offering_id: UUID | None = None,
        cursor: UUID | None = None,
        limit: Annotated[int, Query(ge=1, le=200)] = 50,
    ):
        async with transaction(engine, user.user_id, institute_id) as c:
            st = await bio.student(c, user.user_id, institute_id)
            filters = {"i": institute_id, "o": offering_id, "student": st["id"]}
            at = None
            if cursor is not None:
                # Old publication IDs still resolve after a correction.
                at = await one(
                    c,
                    """SELECT s.id,s.starts_at FROM app.publications p
                    JOIN app.sessions s ON s.institute_id=p.institute_id AND s.id=p.session_id
                    JOIN app.session_roster r ON r.institute_id=s.institute_id AND r.session_id=s.id
                    WHERE p.institute_id=:i AND p.id=:cur AND r.student_id=:student
                    AND (CAST(:o AS uuid) IS NULL OR s.offering_id=CAST(:o AS uuid))""",
                    {**filters, "cur": cursor},
                )
                if not at:
                    raise APIError(
                        422, "INVALID_CURSOR", "The list cursor is not valid. Reload the list."
                    )
            rows = await many(
                c,
                """WITH marks AS (
                    SELECT p.id,p.revision,p.published_at,s.id AS session_id,
                    s.offering_id,s.starts_at AS class_starts_at,
                    p.snapshot_json->>'starts_at' AS starts_at,
                    mark->>'status' AS status,mark->>'reason' AS reason,
                    mark->>'assessment_code' AS assessment_code,
                    '{}'::jsonb AS evidence_summary
                    FROM app.session_roster r
                    JOIN app.sessions s ON s.institute_id=r.institute_id AND s.id=r.session_id
                    JOIN app.publications p ON p.institute_id=s.institute_id AND p.session_id=s.id
                        AND p.revision=s.attendance_revision
                    CROSS JOIN LATERAL jsonb_path_query_first(
                        p.snapshot_json,
                        '$.records[*] ? (@.student_id == $student)'::jsonpath,
                        jsonb_build_object('student', CAST(r.student_id AS text))
                    ) AS mark
                    WHERE r.institute_id=:i AND r.student_id=:student
                    AND (CAST(:o AS uuid) IS NULL OR s.offering_id=CAST(:o AS uuid))
                    AND mark IS NOT NULL
                ), totals AS (
                    SELECT count(*) FILTER (WHERE status IN ('present','late')) AS attended,
                    count(*) FILTER (WHERE status IN ('present','late','absent')) AS assessed,
                    count(*) FILTER (WHERE status NOT IN ('present','late','absent')) AS pending
                    FROM marks
                )
                SELECT totals.*, page.*
                FROM totals LEFT JOIN LATERAL (
                    SELECT id,revision,published_at,session_id,offering_id,starts_at,
                    status,reason,assessment_code,evidence_summary,class_starts_at
                    FROM marks WHERE status IN ('present','late','absent')
                    AND (CAST(:before AS timestamptz) IS NULL OR
                        (class_starts_at,session_id)<(CAST(:before AS timestamptz),CAST(:sid AS uuid)))
                    ORDER BY class_starts_at DESC,session_id DESC LIMIT :n
                ) AS page ON true
                ORDER BY page.class_starts_at DESC,page.session_id DESC""",
                {
                    **filters,
                    "before": at["starts_at"] if at else None,
                    "sid": at["id"] if at else None,
                    "n": limit + 1,
                },
            )
            totals = rows[0]
            present, assessed = totals["attended"], totals["assessed"]
            items = [
                {
                    k: v
                    for k, v in row.items()
                    if k not in ("attended", "assessed", "pending", "class_starts_at")
                }
                for row in rows
                if row["id"] is not None
            ]
            return {
                **page(items, limit),
                "summary": {
                    "present_or_late": present,
                    "assessed": assessed,
                    "unassessed": totals["pending"],
                    "percentage": 100 * present / assessed if assessed else None,
                    "policy_version": "session-v1",
                },
            }

    async def published_summaries(c, institute_id, ids):
        if not ids:
            return {}
        summaries = await many(
            c,
            """WITH published AS (
                    SELECT p.snapshot_json,s.starts_at,s.id,s.offering_id
                    FROM app.publications p JOIN app.sessions s
                      ON (s.institute_id,s.id)=(p.institute_id,p.session_id)
                    WHERE p.institute_id=:i AND s.offering_id=ANY(CAST(:ids AS uuid[])) AND s.status='finalized'
                      AND p.revision=s.attendance_revision
                ), raw_marks AS (
                    SELECT p.offering_id,p.starts_at,p.id,rec.student_id,
                      rec.official_name,rec.enrollment_number,rec.status
                    FROM published p CROSS JOIN LATERAL jsonb_to_recordset(p.snapshot_json->'records')
                      AS rec(student_id text,official_name text,enrollment_number text,status text)
                ), marks AS (
                    SELECT offering_id,student_id,
                      (array_agg(official_name ORDER BY starts_at DESC,id DESC))[1] AS official_name,
                      (array_agg(enrollment_number ORDER BY starts_at DESC,id DESC))[1] AS enrollment_number,
                      count(*) FILTER (WHERE status='present') AS present,
                      count(*) FILTER (WHERE status='late') AS late,
                      count(*) FILTER (WHERE status='absent') AS absent,
                      count(*) FILTER (WHERE status='unassessed') AS unassessed,
                      count(*) FILTER (WHERE status='excused') AS excused,
                      count(*) AS conducted
                    FROM raw_marks GROUP BY offering_id,student_id
                ), monthly AS (
                    SELECT offering_id,to_char(date_trunc('month',starts_at AT TIME ZONE 'Asia/Kolkata'),'YYYY-MM') AS month,
                      count(*) FILTER (WHERE status IN ('present','late')) AS attended,
                      count(*) FILTER (WHERE status IN ('present','late','absent')) AS assessed
                    FROM raw_marks GROUP BY offering_id,date_trunc('month',starts_at AT TIME ZONE 'Asia/Kolkata')
                )
                SELECT selected.offering_id, coalesce(sessions.conducted,0) AS sessions_conducted,
                   coalesce(students.records,'[]') AS students,
                   coalesce(trends.records,'[]') AS monthly
            FROM unnest(CAST(:ids AS uuid[])) AS selected(offering_id)
            LEFT JOIN (SELECT offering_id,count(*) AS conducted FROM published GROUP BY offering_id)
              sessions USING(offering_id)
            LEFT JOIN (SELECT offering_id,jsonb_agg(to_jsonb(marks)-'offering_id') AS records
                       FROM marks GROUP BY offering_id) students USING(offering_id)
            LEFT JOIN (SELECT offering_id,jsonb_agg(
                       jsonb_build_object('month',month,'attended',attended,'assessed',assessed)
                       ORDER BY month) AS records
                       FROM monthly GROUP BY offering_id) trends USING(offering_id)""",
            {"i": institute_id, "ids": ids},
        )
        result = {}
        for summary in summaries:
            students = []
            for acc in summary["students"]:
                attended = acc["present"] + acc["late"]
                assessed = attended + acc["absent"]
                students.append(
                    {
                        **acc,
                        "attended": attended,
                        "assessed": assessed,
                        "percentage": round(100 * attended / assessed, 1) if assessed else None,
                    }
                )
            students.sort(key=lambda x: (x["enrollment_number"] or "", x["student_id"]))
            monthly = [
                {
                    **row,
                    "percentage": round(100 * row["attended"] / row["assessed"], 1)
                    if row["assessed"]
                    else None,
                }
                for row in summary["monthly"]
            ]
            offering_id = summary["offering_id"]
            result[offering_id] = {
                "offering_id": str(offering_id),
                "sessions_conducted": summary["sessions_conducted"],
                "students": students,
                "monthly": monthly,
                "policy_version": "session-v1",
            }
        return result

    @app.get("/v1/offerings/{offering_id}/attendance-summary")
    async def offering_attendance_summary(offering_id: UUID, user: User, institute_id: Institute):
        async with transaction(engine, user.user_id, institute_id) as c:
            await teacher_access(c, user.user_id, institute_id, offering_id)
            return (await published_summaries(c, institute_id, [offering_id]))[offering_id]

    @app.get("/v1/teacher/attendance-dashboard")
    async def teacher_attendance_dashboard(
        user: User,
        institute_id: Institute,
        cursor: UUID | None = None,
        limit: Annotated[int, Query(ge=1, le=100)] = 25,
    ):
        async with transaction(engine, user.user_id, institute_id) as c:
            offerings = await services.offering_list(
                c, user.user_id, institute_id, cursor, limit, faculty_only=True
            )
            summaries = await published_summaries(
                c, institute_id, [o["id"] for o in offerings["items"]]
            )
            return {
                "items": [
                    {"offering": o, "summary": summaries[o["id"]]} for o in offerings["items"]
                ],
                "next_cursor": offerings["next_cursor"],
            }

    @app.post("/v1/me/attendance/{publication_id}/disputes", status_code=201)
    async def create_dispute(
        publication_id: UUID,
        body: DisputeCreate,
        request: Request,
        user: User,
        institute_id: Institute,
        key: Key,
    ):
        async with transaction(engine, user.user_id, institute_id) as c:
            st = await bio.student(c, user.user_id, institute_id)
            route = request.url.path
            cached, fp = await idempotent(
                c, user.user_id, institute_id, route, key, body.model_dump()
            )
            if cached:
                return cached
            publication = await one(
                c,
                """SELECT p.*,s.attendance_revision,s.offering_id FROM app.publications p
                JOIN app.sessions s ON s.institute_id=p.institute_id AND s.id=p.session_id
                WHERE p.institute_id=:i AND p.id=:p AND p.revision=s.attendance_revision
                AND EXISTS(SELECT 1 FROM app.session_roster r WHERE r.institute_id=p.institute_id
                AND r.session_id=p.session_id AND r.student_id=:student) FOR UPDATE OF s""",
                {"i": institute_id, "p": publication_id, "student": st["id"]},
            )
            if not publication:
                raise APIError(404, "NOT_FOUND", "Published attendance result not found.")
            mine = next(
                (
                    x
                    for x in publication["snapshot_json"]["records"]
                    if x["student_id"] == str(st["id"])
                ),
                None,
            )
            if not mine or mine["status"] != "absent":
                raise APIError(
                    409,
                    "DISPUTE_NOT_AVAILABLE",
                    "Only your latest published Absent result can be queried.",
                )
            row = dict(
                await one(
                    c,
                    """INSERT INTO app.attendance_disputes(
                    institute_id,session_id,student_id,source_publication_id,source_revision,student_reason)
                    VALUES(:i,:s,:student,:p,:revision,:reason) RETURNING *""",
                    {
                        "i": institute_id,
                        "s": publication["session_id"],
                        "student": st["id"],
                        "p": publication_id,
                        "revision": publication["revision"],
                        "reason": body.reason.strip(),
                    },
                )
            )
            await audit(
                c,
                user.user_id,
                institute_id,
                "attendance.dispute_created",
                "attendance_dispute",
                row["id"],
                request.state.request_id,
            )
            await remember(c, user.user_id, institute_id, route, key, fp, row, 201)
            return row

    @app.get("/v1/me/attendance-disputes")
    async def own_disputes(
        user: User,
        institute_id: Institute,
        cursor: UUID | None = None,
        limit: Annotated[int, Query(ge=1, le=200)] = 50,
    ):
        async with transaction(engine, user.user_id, institute_id) as c:
            st = await bio.student(c, user.user_id, institute_id)
            await check_cursor(
                c,
                cursor,
                """SELECT 1 FROM app.attendance_disputes
                WHERE institute_id=:i AND student_id=:student AND id=CAST(:cur AS uuid)""",
                {"i": institute_id, "student": st["id"]},
            )
            rows = await many(
                c,
                """SELECT d.*,s.offering_id,s.starts_at FROM app.attendance_disputes d
                JOIN app.sessions s ON s.institute_id=d.institute_id AND s.id=d.session_id
                WHERE d.institute_id=:i AND d.student_id=:student
                AND (CAST(:cur AS uuid) IS NULL OR (d.created_at,d.id)<(SELECT created_at,id
                  FROM app.attendance_disputes WHERE institute_id=:i AND id=CAST(:cur AS uuid)))
                ORDER BY d.created_at DESC,d.id DESC LIMIT :n""",
                {
                    "i": institute_id,
                    "student": st["id"],
                    "cur": str(cursor) if cursor else None,
                    "n": limit + 1,
                },
            )
            return page(rows, limit)

    @app.get("/v1/offerings/{offering_id}/attendance-disputes")
    async def offering_disputes(
        offering_id: UUID,
        user: User,
        institute_id: Institute,
        status: Literal["open", "accepted", "rejected", "withdrawn"] = "open",
        cursor: UUID | None = None,
        limit: Annotated[int, Query(ge=1, le=200)] = 50,
    ):
        async with transaction(engine, user.user_id, institute_id) as c:
            await teacher_access(c, user.user_id, institute_id, offering_id)
            await check_cursor(
                c,
                cursor,
                """SELECT 1 FROM app.attendance_disputes d JOIN app.sessions s
                ON s.institute_id=d.institute_id AND s.id=d.session_id
                WHERE d.institute_id=:i AND s.offering_id=:o AND d.id=CAST(:cur AS uuid)""",
                {"i": institute_id, "o": offering_id},
            )
            rows = await many(
                c,
                """SELECT d.*,r.name_snapshot AS official_name,
                r.enrollment_number_snapshot AS enrollment_number,s.starts_at
                FROM app.attendance_disputes d
                JOIN app.sessions s ON s.institute_id=d.institute_id AND s.id=d.session_id
                JOIN app.session_roster r ON r.institute_id=d.institute_id
                  AND r.session_id=d.session_id AND r.student_id=d.student_id
                WHERE d.institute_id=:i AND s.offering_id=:o AND d.status=:status
                AND (CAST(:cur AS uuid) IS NULL OR (d.created_at,d.id)<(SELECT created_at,id
                  FROM app.attendance_disputes WHERE institute_id=:i AND id=CAST(:cur AS uuid)))
                ORDER BY d.created_at DESC,d.id DESC LIMIT :n""",
                {
                    "i": institute_id,
                    "o": offering_id,
                    "status": status,
                    "cur": str(cursor) if cursor else None,
                    "n": limit + 1,
                },
            )
            return page(rows, limit)

    @app.post("/v1/attendance-disputes/{identifier}/resolve")
    async def resolve_dispute(
        identifier: UUID,
        body: DisputeResolution,
        request: Request,
        user: User,
        institute_id: Institute,
        key: Key,
        version: Version,
    ):
        async with transaction(engine, user.user_id, institute_id) as c:
            row = await one(
                c,
                """SELECT d.*,s.offering_id,s.status AS session_status,s.attendance_revision,s.version AS session_version
                FROM app.attendance_disputes d JOIN app.sessions s
                ON s.institute_id=d.institute_id AND s.id=d.session_id
                WHERE d.institute_id=:i AND d.id=:id FOR UPDATE OF d,s""",
                {"i": institute_id, "id": identifier},
            )
            if not row:
                raise APIError(404, "NOT_FOUND", "Attendance query not found.")
            await teacher_access(c, user.user_id, institute_id, row["offering_id"])
            # Rejecting is as final as accepting: both need the publishing assignment.
            await can_publish(c, user.user_id, institute_id, row["offering_id"])
            route = request.url.path
            cached, fp = await idempotent(
                c,
                user.user_id,
                institute_id,
                route,
                key,
                {"body": body.model_dump(), "version": version},
            )
            if cached:
                return cached
            if row["version"] != expected_version(version) or row["status"] != "open":
                raise APIError(409, "VERSION_CONFLICT", "Refresh this attendance query.")
            publication_id = None
            if body.decision == "accepted":
                if row["session_status"] != "finalized" or not await still_absent(
                    c, institute_id, row
                ):
                    raise APIError(
                        409,
                        "PUBLICATION_CHANGED",
                        "Attendance changed after this query. Refresh before resolving it.",
                    )
                await apply_decisions(
                    c,
                    user.user_id,
                    institute_id,
                    row["session_id"],
                    [
                        Decision(
                            student_id=row["student_id"],
                            status="present",
                            reason=body.reason.strip(),
                        )
                    ],
                )
                s = await one(
                    c,
                    "SELECT * FROM app.sessions WHERE institute_id=:i AND id=:id",
                    {"i": institute_id, "id": row["session_id"]},
                )
                publication_id = (await publish(c, user.user_id, institute_id, s, body.reason))[
                    "id"
                ]
            result = dict(
                await one(
                    c,
                    """UPDATE app.attendance_disputes SET status=:status,resolution_reason=:reason,
                    resolved_by=:actor,resolved_at=now(),resolved_publication_id=:publication,
                    updated_at=now(),version=version+1
                    WHERE institute_id=:i AND id=:id RETURNING *""",
                    {
                        "status": body.decision,
                        "reason": body.reason.strip(),
                        "actor": user.user_id,
                        "publication": publication_id,
                        "i": institute_id,
                        "id": identifier,
                    },
                )
            )
            await audit(
                c,
                user.user_id,
                institute_id,
                "attendance.dispute_" + body.decision,
                "attendance_dispute",
                identifier,
                request.state.request_id,
            )
            await remember(c, user.user_id, institute_id, route, key, fp, result, 200)
            return result

    @app.post("/v1/sessions/{identifier}/captures", status_code=201)
    async def create_capture(
        identifier: UUID,
        body: CaptureCreate,
        request: Request,
        user: User,
        institute_id: Institute,
        key: Key,
    ):
        async with transaction(engine, user.user_id, institute_id) as c:
            s = await session(c, user.user_id, institute_id, identifier, lock=True)
            route = request.url.path
            cached, fp = await idempotent(
                c, user.user_id, institute_id, route, key, body.model_dump()
            )
            if cached:
                return cached
            if s["status"] != "open" or bio.now() > s["ends_at"] + timedelta(minutes=5):
                raise APIError(
                    409,
                    "SESSION_STATE",
                    "Capture requires an open session within its capture window.",
                )
            if (
                not s["starts_at"] - timedelta(minutes=5)
                <= body.recorded_at
                <= min(bio.now() + timedelta(minutes=2), s["ends_at"] + timedelta(minutes=5))
            ):
                raise APIError(422, "CAPTURE_TIME", "The recording time is outside this session.")
            available = await many(
                c,
                f"""SELECT r.student_id FROM app.session_roster r
                    {FROZEN_ELIGIBILITY_JOINS}
                    WHERE r.institute_id=:i AND r.session_id=:s AND {FROZEN_ELIGIBILITY}
                    LIMIT 2""",
                {"i": institute_id, "s": identifier},
            )
            if len(available) < 2:
                raise APIError(
                    409,
                    "INSUFFICIENT_TEMPLATES",
                    "At least two students need compatible active face enrolments. You can still assess attendance manually.",
                )
            await c.execute(
                text("SELECT pg_advisory_xact_lock(hashtextextended(:x,0))"),
                {"x": "capture-quota:" + str(institute_id)},
            )
            quotas = await one(
                c,
                """SELECT
            (SELECT count(*) FROM app.captures WHERE institute_id=:i AND session_id=:s AND status IN ('awaiting_upload','queued','processing')) AS session_pending,
            (SELECT count(*) FROM app.captures WHERE institute_id=:i AND submitted_by=:u AND status='awaiting_upload') AS teacher_uploads,
            (SELECT count(*) FROM app.jobs WHERE institute_id=:i AND kind='recognition' AND state IN ('queued','leased','running','retry_wait')) AS institute_pending""",
                {"i": institute_id, "s": identifier, "u": user.user_id},
            )
            if (
                quotas["session_pending"] >= 3
                or quotas["teacher_uploads"] >= 2
                or quotas["institute_pending"] >= 100
            ):
                raise APIError(
                    429,
                    "CAPTURE_LIMIT",
                    "Wait for pending uploads/processing to finish before adding another capture.",
                    retryable=True,
                )
            asset, cap = uuid4(), uuid4()
            await c.execute(
                text("""INSERT INTO app.media_assets(id,institute_id,owner_user_id,purpose,bucket,object_key,mime_type,expected_bytes)
            VALUES(:id,:i,:u,'classroom',:b,:k,:m,:n)"""),
                {
                    "id": asset,
                    "i": institute_id,
                    "u": user.user_id,
                    "b": settings.enrollment_bucket,
                    "k": f"classroom/{uuid4().hex}/{asset.hex}",
                    "m": body.mime_type,
                    "n": body.expected_bytes,
                },
            )
            row = dict(
                await one(
                    c,
                    """INSERT INTO app.captures(id,institute_id,session_id,asset_id,submitted_by,source_type,recorded_at)
            VALUES(:id,:i,:s,:a,:u,:type,:at) RETURNING *""",
                    {
                        "id": cap,
                        "i": institute_id,
                        "s": identifier,
                        "a": asset,
                        "u": user.user_id,
                        "type": body.source_type,
                        "at": body.recorded_at,
                    },
                )
            )
            await remember(c, user.user_id, institute_id, route, key, fp, row, 201)
            return row

    async def capture_owned(c, user, institute, identifier, lock=False):
        cap = await one(
            c,
            "SELECT * FROM app.captures WHERE institute_id=:i AND id=:id",
            {"i": institute, "id": identifier},
        )
        if not cap:
            raise APIError(404, "NOT_FOUND", "Capture not found.")
        s = await session(c, user, institute, cap["session_id"], lock=lock)
        asset = await one(
            c,
            "SELECT * FROM app.media_assets WHERE institute_id=:i AND id=:id",
            {"i": institute, "id": cap["asset_id"]},
        )
        return cap, s, dict(asset)

    @app.get("/v1/captures/{identifier}")
    async def capture_status(identifier: UUID, user: User, institute_id: Institute):
        async with transaction(engine, user.user_id, institute_id) as c:
            cap, _, _ = await capture_owned(c, user.user_id, institute_id, identifier)
            job = await one(
                c,
                "SELECT id,state,stage,error_code FROM app.jobs WHERE institute_id=:i AND capture_id=:id",
                {"i": institute_id, "id": identifier},
            )
            return {**dict(cap), "job": dict(job) if job else None}

    @app.post("/v1/captures/{identifier}/upload-grant")
    async def capture_grant(identifier: UUID, user: User, institute_id: Institute):
        async with transaction(engine, user.user_id, institute_id) as c:
            cap, s, asset = await capture_owned(
                c, user.user_id, institute_id, identifier, lock=True
            )
            if (
                cap["status"] != "awaiting_upload"
                or s["status"] != "open"
                or asset["reservation_expires_at"] <= bio.now()
            ):
                raise APIError(
                    409,
                    "UPLOAD_EXPIRED",
                    "Capture upload is closed; record again in an open session.",
                )
            await c.execute(
                text(
                    "UPDATE app.media_assets SET grant_expires_at=now()+interval '2 hours' WHERE institute_id=:i AND id=:id"
                ),
                {"i": institute_id, "id": asset["id"]},
            )
        return await storage.upload(asset)

    from .biometric_types import UploadComplete

    @app.post("/v1/captures/{identifier}/upload-complete", status_code=202)
    async def capture_complete(
        identifier: UUID,
        body: UploadComplete,
        request: Request,
        user: User,
        institute_id: Institute,
        key: Key,
    ):
        route = request.url.path
        async with transaction(engine, user.user_id, institute_id) as c:
            cap, _, asset = await capture_owned(c, user.user_id, institute_id, identifier)
            cached, _ = await idempotent(
                c, user.user_id, institute_id, route, key, body.model_dump()
            )
            if cached:
                return cached
        info = await storage.info(asset)
        async with transaction(engine, user.user_id, institute_id) as c:
            cap, s, asset = await capture_owned(
                c, user.user_id, institute_id, identifier, lock=True
            )
            cached, fp = await idempotent(
                c, user.user_id, institute_id, route, key, body.model_dump()
            )
            if cached:
                return cached
            if (
                cap["status"] != "awaiting_upload"
                or s["status"] != "open"
                or asset["reservation_expires_at"] <= bio.now()
            ):
                raise APIError(409, "UPLOAD_EXPIRED", "Capture upload is closed.")
            if (
                body.asset_id != asset["id"]
                or body.byte_size != asset["expected_bytes"]
                or info["size"] != body.byte_size
                or info["mime_type"].split(";")[0] != asset["mime_type"]
            ):
                raise APIError(
                    409, "MEDIA_MISMATCH", "The uploaded capture does not match its reservation."
                )
            await c.execute(
                text(
                    "UPDATE app.media_assets SET status='uploaded',byte_size=:n,sha256=:h WHERE institute_id=:i AND id=:id"
                ),
                {"n": body.byte_size, "h": body.sha256, "i": institute_id, "id": asset["id"]},
            )
            await c.execute(
                text(
                    "UPDATE app.captures SET status='queued',version=version+1 WHERE institute_id=:i AND id=:id"
                ),
                {"i": institute_id, "id": identifier},
            )
            job = await one(
                c,
                "INSERT INTO app.jobs(institute_id,kind,capture_id,dedup_key,generation) VALUES(:i,'recognition',:id,:key,:g) RETURNING id",
                {
                    "i": institute_id,
                    "id": identifier,
                    "key": f"capture:{identifier}:{cap['generation']}",
                    "g": cap["generation"],
                },
            )
            result = {
                "job_id": str(job["id"]),
                "resource_id": str(identifier),
                "state": "queued",
                "status_url": f"/v1/captures/{identifier}",
            }
            await remember(c, user.user_id, institute_id, route, key, fp, result, 202)
            return result
