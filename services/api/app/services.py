from datetime import datetime, timedelta, timezone
from uuid import UUID
from zoneinfo import ZoneInfo

from sqlalchemy import text

from .db import many, one
from .errors import APIError
from .security import (
    audit,
    check_cursor,
    code_hash,
    code_quota,
    encrypted_code,
    idempotent,
    page,
    remember,
    reveal_code,
    roles,
    teacher_access,
)

OFFERING_FIELDS = "o.id,o.course_id,o.term_id,o.class_group_id,o.title,o.status,o.roster_version,o.version,c.code AS course_code,t.code AS term_code,g.branch,g.semester,g.section"
OFFERING_JOINS = "JOIN app.courses c ON c.institute_id=o.institute_id AND c.id=o.course_id JOIN app.terms t ON t.institute_id=o.institute_id AND t.id=o.term_id JOIN app.class_groups g ON g.institute_id=o.institute_id AND g.id=o.class_group_id"


async def summary(conn, institute, offering):
    return dict(
        await one(
            conn,
            f"SELECT {OFFERING_FIELDS} FROM app.offerings o {OFFERING_JOINS} WHERE o.institute_id=:i AND o.id=:o",
            {"i": institute, "o": offering},
        )
    )


async def staff(conn, actor, institute):
    permissions = await roles(conn, actor, institute)
    if "admin" in permissions:
        return permissions
    if "teacher" in permissions and await one(
        conn,
        """SELECT id FROM app.teachers
        WHERE institute_id=:i AND auth_user_id=:a AND status='approved'""",
        {"i": institute, "a": actor},
    ):
        return permissions
    raise APIError(403, "STAFF_REQUIRED", "Approved faculty access is required.")


async def me(conn, actor):
    memberships = await many(
        conn,
        """SELECT m.id,m.institute_id,i.name AS institute_name,m.role,m.status
        FROM app.memberships m JOIN app.institutes i ON i.id=m.institute_id
        WHERE m.auth_user_id=:a ORDER BY m.institute_id,m.role""",
        {"a": actor},
    )
    result = {"user_id": actor, "memberships": [dict(m) for m in memberships]}
    for kind in ("students", "teachers"):
        number = "enrollment_number" if kind == "students" else "employee_number"
        rows = await many(
            conn,
            f"SELECT id,institute_id,{number},official_name,status FROM app.{kind} WHERE auth_user_id=:a ORDER BY id",
            {"a": actor},
        )
        result[kind] = [dict(r) for r in rows]
    return result


async def claim(conn, actor, institute, email, body, key, request_id):
    route = "/v1/identity/claim"
    cached, fingerprint = await idempotent(conn, actor, institute, route, key, body.model_dump())
    # Never disclose whether a different-email or already-claimed approved record exists.
    student = await one(
        conn,
        """SELECT id,auth_user_id FROM app.students WHERE institute_id=:i
        AND enrollment_number=:n AND official_email=:email AND status='approved' FOR UPDATE""",
        {"i": institute, "n": body.enrollment_number, "email": email},
    )
    if not student or student["auth_user_id"] not in (None, actor):
        raise APIError(
            404, "CLAIM_UNAVAILABLE", "Approved identity cannot be linked. Contact the institute."
        )
    existing = await one(
        conn,
        """SELECT status FROM app.memberships WHERE institute_id=:i
        AND auth_user_id=:a AND role='student'""",
        {"i": institute, "a": actor},
    )
    if existing and existing["status"] != "active":
        raise APIError(403, "MEMBERSHIP_INACTIVE", "The institute must reactivate this membership.")
    if cached:
        return cached
    if student["auth_user_id"] is None:
        await conn.execute(
            text("""UPDATE app.students SET auth_user_id=:a,version=version+1,
            updated_at=now() WHERE institute_id=:i AND id=:s"""),
            {"i": institute, "a": actor, "s": student["id"]},
        )
    if not existing:
        await conn.execute(
            text("""INSERT INTO app.memberships(institute_id,auth_user_id,role)
            VALUES (:i,:a,'student')"""),
            {"i": institute, "a": actor},
        )
    result = {"student_id": str(student["id"]), "institute_id": str(institute), "status": "linked"}
    await audit(conn, actor, institute, "identity.claimed", "student", student["id"], request_id)
    await remember(conn, actor, institute, route, key, fingerprint, result)
    return result


async def academics(conn, actor, institute, kind, cursor, limit):
    await staff(conn, actor, institute)
    columns = {
        "courses": "id,code,title,status,version",
        "terms": "id,code,starts_on,ends_on,version",
        "class-groups": "id,term_id,branch,semester,section,version",
    }
    table = {"courses": "courses", "terms": "terms", "class-groups": "class_groups"}
    # Sort key and the comparison that selects rows after the cursor row.
    key, after, order = {
        "courses": ("code,id", ">", "code,id"),
        "terms": ("starts_on,id", "<", "starts_on DESC,id DESC"),
        "class-groups": ("branch,semester,section,id", ">", "branch,semester,section,id"),
    }[kind]
    await check_cursor(
        conn,
        cursor,
        f"SELECT 1 FROM app.{table[kind]} WHERE institute_id=:i AND id=CAST(:cur AS uuid)",
        {"i": institute},
    )
    rows = await many(
        conn,
        f"""SELECT {columns[kind]} FROM app.{table[kind]} WHERE institute_id=:i
        AND (CAST(:cursor AS uuid) IS NULL OR ({key}){after}(SELECT {key} FROM app.{table[kind]}
          WHERE institute_id=:i AND id=CAST(:cursor AS uuid)))
        ORDER BY {order} LIMIT :limit""",
        {"i": institute, "cursor": cursor, "limit": limit + 1},
    )
    return page(rows, limit)


async def offering_list(conn, actor, institute, cursor, limit):
    permissions = await roles(conn, actor, institute)
    await check_cursor(
        conn,
        cursor,
        "SELECT 1 FROM app.offerings WHERE institute_id=:i AND id=CAST(:cur AS uuid)",
        {"i": institute},
    )
    query = f"""SELECT {OFFERING_FIELDS}
        FROM app.offerings o {OFFERING_JOINS} WHERE o.institute_id=:i AND (CAST(:cursor AS uuid) IS NULL
        OR (c.code,g.section,o.id)>(SELECT c2.code,g2.section,o2.id FROM app.offerings o2
          JOIN app.courses c2 ON c2.institute_id=o2.institute_id AND c2.id=o2.course_id
          JOIN app.class_groups g2 ON g2.institute_id=o2.institute_id AND g2.id=o2.class_group_id
          WHERE o2.institute_id=:i AND o2.id=CAST(:cursor AS uuid))) AND (
        :admin OR EXISTS (SELECT 1 FROM app.offering_teachers ot JOIN app.teachers t
        ON t.institute_id=ot.institute_id AND t.id=ot.teacher_id
        WHERE ot.institute_id=o.institute_id AND ot.offering_id=o.id AND ot.status='active'
        AND t.auth_user_id=:a AND t.status='approved' AND :faculty)
        OR EXISTS (SELECT 1 FROM app.course_enrollments e JOIN app.students s
        ON s.institute_id=e.institute_id AND s.id=e.student_id
        WHERE e.institute_id=o.institute_id AND e.offering_id=o.id
        AND e.status IN ('requested','active') AND s.auth_user_id=:a AND s.status='approved'
        AND :student)) ORDER BY c.code,g.section,o.id LIMIT :limit"""
    rows = await many(
        conn,
        query,
        {
            "i": institute,
            "a": actor,
            "admin": "admin" in permissions,
            "faculty": "teacher" in permissions,
            "student": "student" in permissions,
            "cursor": cursor,
            "limit": limit + 1,
        },
    )
    return page(rows, limit)


async def offering_detail(conn, actor, institute, offering):
    permissions = await roles(conn, actor, institute)
    if {"teacher", "admin"} & permissions:
        try:
            await teacher_access(conn, actor, institute, offering)
            return await summary(conn, institute, offering)
        except APIError as exc:
            if exc.status != 404 or "student" not in permissions:
                raise
    student = await one(
        conn,
        """SELECT o.id,o.course_id,o.term_id,o.class_group_id,o.title,o.status,o.roster_version,o.version
        FROM app.offerings o JOIN app.course_enrollments e ON e.institute_id=o.institute_id AND e.offering_id=o.id
        JOIN app.students s ON s.institute_id=e.institute_id AND s.id=e.student_id
        WHERE o.institute_id=:i AND o.id=:o AND s.auth_user_id=:a AND s.status='approved'
        AND e.status IN ('requested','active')""",
        {"i": institute, "o": offering, "a": actor},
    )
    if not student or "student" not in permissions:
        raise APIError(404, "NOT_FOUND", "Offering not found.")
    return await summary(conn, institute, offering)


async def create_offering(conn, actor, institute, body, key, request_id):
    permissions = await staff(conn, actor, institute)
    route = "/v1/offerings"
    cached, fingerprint = await idempotent(
        conn, actor, institute, route, key, body.model_dump(mode="json")
    )
    if cached:
        await teacher_access(conn, actor, institute, UUID(cached["id"]))
        return {**await summary(conn, institute, UUID(cached["id"])), **cached}
    teacher = await one(
        conn,
        """SELECT t.id FROM app.teachers t WHERE t.institute_id=:i
        AND t.status='approved' AND ((CAST(:teacher AS uuid) IS NOT NULL AND t.id=:teacher AND :admin)
        OR (CAST(:teacher AS uuid) IS NULL AND t.auth_user_id=:a))""",
        {"i": institute, "teacher": body.teacher_id, "admin": "admin" in permissions, "a": actor},
    )
    # A narrowly scoped DB trigger checks the selected faculty's active membership.
    if not teacher:
        raise APIError(
            422, "TEACHER_UNAVAILABLE", "An approved linked faculty profile is required."
        )
    course = await one(
        conn,
        "SELECT title FROM app.courses WHERE institute_id=:i AND id=:c AND status='active'",
        {"i": institute, "c": body.course_id},
    )
    group = await one(
        conn,
        "SELECT id FROM app.class_groups WHERE institute_id=:i AND id=:g AND term_id=:t",
        {"i": institute, "g": body.class_group_id, "t": body.term_id},
    )
    if not course or not group:
        raise APIError(
            422,
            "ACADEMIC_REFERENCE_INVALID",
            "Course, class group and term must be valid in this institute.",
        )
    row = await one(
        conn,
        """INSERT INTO app.offerings(institute_id,course_id,term_id,class_group_id,title)
        VALUES (:i,:c,:t,:g,:title) RETURNING id,course_id,term_id,class_group_id,title,status,roster_version,version""",
        {
            "i": institute,
            "c": body.course_id,
            "t": body.term_id,
            "g": body.class_group_id,
            "title": course["title"],
        },
    )
    await conn.execute(
        text("""INSERT INTO app.offering_teachers(institute_id,offering_id,teacher_id)
        VALUES (:i,:o,:t)"""),
        {"i": institute, "o": row["id"], "t": teacher["id"]},
    )
    result = await summary(conn, institute, row["id"])
    await audit(conn, actor, institute, "offering.created", "offering", row["id"], request_id)
    await remember(conn, actor, institute, route, key, fingerprint, result)
    return result


async def rotate_code(conn, actor, institute, offering, key, version, settings, request_id):
    row = await teacher_access(conn, actor, institute, offering, lock=True)
    route = f"/v1/offerings/{offering}/join-code"
    cached, fingerprint = await idempotent(conn, actor, institute, route, key, {"version": version})
    if cached:
        code = await one(
            conn,
            """SELECT * FROM app.offering_join_codes WHERE institute_id=:i
            AND id=:id AND revoked_at IS NULL AND expires_at>now()""",
            {"i": institute, "id": UUID(cached["code_id"])},
        )
        if not code:
            raise APIError(
                409, "CODE_SUPERSEDED", "Code was rotated or expired; request a new code."
            )
        return reveal_code(settings, code)
    if row["version"] != version:
        raise APIError(
            409, "VERSION_CONFLICT", "Offering changed; refresh before rotating its code."
        )
    if row["status"] != "active":
        raise APIError(409, "OFFERING_INACTIVE", "Offering is not active.")
    term = await one(
        conn,
        "SELECT ends_on FROM app.terms WHERE institute_id=:i AND id=:t",
        {"i": institute, "t": row["term_id"]},
    )
    expiry = min(
        datetime.now(timezone.utc) + timedelta(days=7),
        datetime.combine(
            term["ends_on"] + timedelta(days=1),
            datetime.min.time(),
            tzinfo=ZoneInfo("Asia/Kolkata"),
        ),
    )
    if expiry <= datetime.now(timezone.utc):
        raise APIError(409, "TERM_ENDED", "Term has ended.")
    await conn.execute(
        text(
            "UPDATE app.offering_join_codes SET revoked_at=now(),updated_at=now() WHERE institute_id=:i AND offering_id=:o AND revoked_at IS NULL"
        ),
        {"i": institute, "o": offering},
    )
    code = encrypted_code(settings, institute, offering)
    saved = await one(
        conn,
        """INSERT INTO app.offering_join_codes
        (id,institute_id,offering_id,code_hash,ciphertext,nonce,key_id,expires_at)
        VALUES (:id,:i,:o,:code_hash,:ciphertext,:nonce,:key_id,:expiry) RETURNING *""",
        {**code, "i": institute, "o": offering, "expiry": expiry},
    )
    await conn.execute(
        text(
            "UPDATE app.offerings SET version=version+1,updated_at=now() WHERE institute_id=:i AND id=:o"
        ),
        {"i": institute, "o": offering},
    )
    await audit(conn, actor, institute, "offering.code_rotated", "offering", offering, request_id)
    # Never persist the clear code in an idempotency response; recover after reauthorization.
    await remember(conn, actor, institute, route, key, fingerprint, {"code_id": str(code["id"])})
    return reveal_code(settings, saved)


async def request_enrollment(conn, actor, institute, body, key, request_id):
    permissions = await roles(conn, actor, institute)
    student = await one(
        conn,
        "SELECT id FROM app.students WHERE institute_id=:i AND auth_user_id=:a AND status='approved'",
        {"i": institute, "a": actor},
    )
    if "student" not in permissions or not student:
        raise APIError(403, "STUDENT_REQUIRED", "A linked approved student is required.")
    route = "/v1/enrollment-requests"
    # Persist only a digest of the join-code body in idempotency metadata.
    cached, fingerprint = await idempotent(
        conn, actor, institute, route, key, {"code_hash": code_hash(body.join_code)}
    )
    if cached:
        return cached
    await code_quota(conn, actor, institute)
    code = await one(
        conn,
        """SELECT offering_id FROM app.offering_join_codes WHERE institute_id=:i
        AND code_hash=:h AND revoked_at IS NULL AND expires_at>now()""",
        {"i": institute, "h": code_hash(body.join_code)},
    )
    if not code:
        raise APIError(
            404,
            "JOIN_CODE_UNAVAILABLE",
            "Join code is invalid, expired or unavailable.",
            commit=True,
        )
    # Same lock order as code rotation and approval. Recheck after locking, so rotated codes cannot race.
    offering = await one(
        conn,
        "SELECT status FROM app.offerings WHERE institute_id=:i AND id=:o FOR UPDATE",
        {"i": institute, "o": code["offering_id"]},
    )
    valid = await one(
        conn,
        "SELECT id FROM app.offering_join_codes WHERE institute_id=:i AND offering_id=:o AND code_hash=:h AND revoked_at IS NULL AND expires_at>now()",
        {"i": institute, "o": code["offering_id"], "h": code_hash(body.join_code)},
    )
    if offering["status"] != "active" or not valid:
        raise APIError(
            404,
            "JOIN_CODE_UNAVAILABLE",
            "Join code is invalid, expired or unavailable.",
            commit=True,
        )
    row = await one(
        conn,
        "SELECT id,offering_id,student_id,status,version FROM app.course_enrollments WHERE institute_id=:i AND offering_id=:o AND student_id=:s",
        {"i": institute, "o": code["offering_id"], "s": student["id"]},
    )
    if row and row["status"] in {"rejected", "withdrawn"}:
        raise APIError(
            409, "ENROLLMENT_REQUIRES_FACULTY", "Contact faculty to reconsider this enrolment."
        )
    if not row:
        row = await one(
            conn,
            """INSERT INTO app.course_enrollments(institute_id,offering_id,student_id)
            VALUES (:i,:o,:s) RETURNING id,offering_id,student_id,status,version""",
            {"i": institute, "o": code["offering_id"], "s": student["id"]},
        )
        await audit(
            conn,
            actor,
            institute,
            "enrollment.requested",
            "course_enrollment",
            row["id"],
            request_id,
        )
    result = dict(row)
    await remember(conn, actor, institute, route, key, fingerprint, result)
    return result


async def roster(conn, actor, institute, offering, cursor, limit, status=None):
    await teacher_access(conn, actor, institute, offering)
    await check_cursor(
        conn,
        cursor,
        """SELECT 1 FROM app.course_enrollments
        WHERE institute_id=:i AND offering_id=:o AND id=CAST(:cur AS uuid)""",
        {"i": institute, "o": offering},
    )
    rows = await many(
        conn,
        """SELECT e.id,e.offering_id,e.student_id,e.status,e.version,
        s.enrollment_number,s.official_name FROM app.course_enrollments e
        JOIN app.students s ON s.institute_id=e.institute_id AND s.id=e.student_id
        WHERE e.institute_id=:i AND e.offering_id=:o AND (CAST(:cursor AS uuid) IS NULL
          OR (s.enrollment_number,e.id)>(SELECT s2.enrollment_number,e2.id FROM app.course_enrollments e2
            JOIN app.students s2 ON s2.institute_id=e2.institute_id AND s2.id=e2.student_id
            WHERE e2.institute_id=:i AND e2.id=CAST(:cursor AS uuid)))
        AND (CAST(:status AS text) IS NULL OR e.status=:status)
        ORDER BY s.enrollment_number,e.id LIMIT :limit""",
        {"i": institute, "o": offering, "cursor": cursor, "limit": limit + 1, "status": status},
    )
    return page(rows, limit)


async def approve(conn, actor, institute, offering, enrollment, body, key, version, request_id):
    await teacher_access(conn, actor, institute, offering, lock=True)
    route = f"/v1/offerings/{offering}/enrollments/{enrollment}"
    cached, fingerprint = await idempotent(
        conn, actor, institute, route, key, {**body.model_dump(), "version": version}
    )
    if cached:
        return cached
    current = await one(
        conn,
        "SELECT id,student_id,status,version FROM app.course_enrollments WHERE institute_id=:i AND offering_id=:o AND id=:id FOR UPDATE",
        {"i": institute, "o": offering, "id": enrollment},
    )
    if not current:
        raise APIError(404, "NOT_FOUND", "Enrolment not found.")
    if current["version"] != version:
        raise APIError(409, "VERSION_CONFLICT", "Enrolment changed; refresh before reviewing.")
    student = await one(
        conn,
        "SELECT status FROM app.students WHERE institute_id=:i AND id=:s",
        {"i": institute, "s": current["student_id"]},
    )
    if body.status == "active" and student["status"] != "approved":
        raise APIError(409, "STUDENT_INACTIVE", "Inactive students cannot be approved.")
    row = await one(
        conn,
        """UPDATE app.course_enrollments SET status=:status,reason=:reason,
        approved_by=:a,version=version+1,updated_at=now(),
        effective_from=CASE WHEN :status='active' AND status<>'active' THEN now() ELSE effective_from END,
        effective_until=CASE WHEN :status='active' THEN NULL ELSE now() END
        WHERE institute_id=:i AND id=:id RETURNING id,offering_id,student_id,status,version""",
        {
            "i": institute,
            "id": enrollment,
            "a": actor,
            "status": body.status,
            "reason": body.reason,
        },
    )
    await conn.execute(
        text(
            "UPDATE app.offerings SET roster_version=roster_version+1,version=version+1,updated_at=now() WHERE institute_id=:i AND id=:o"
        ),
        {"i": institute, "o": offering},
    )
    await audit(
        conn, actor, institute, "enrollment.reviewed", "course_enrollment", enrollment, request_id
    )
    result = dict(row)
    await remember(conn, actor, institute, route, key, fingerprint, result, 200)
    return result


async def current_code(conn, actor, institute, offering, settings):
    await teacher_access(conn, actor, institute, offering)
    row = await one(
        conn,
        """SELECT * FROM app.offering_join_codes WHERE institute_id=:i
        AND offering_id=:o AND revoked_at IS NULL AND expires_at>now()""",
        {"i": institute, "o": offering},
    )
    if not row:
        raise APIError(404, "JOIN_CODE_UNAVAILABLE", "No current join code is available.")
    return reveal_code(settings, row)


async def own_enrollments(conn, actor, institute, cursor, limit):
    permissions = await roles(conn, actor, institute)
    if "student" not in permissions:
        raise APIError(403, "STUDENT_REQUIRED", "An active student membership is required.")
    fields = [
        ("id", "o.id"),
        ("course_id", "o.course_id"),
        ("term_id", "o.term_id"),
        ("class_group_id", "o.class_group_id"),
        ("title", "o.title"),
        ("status", "o.status"),
        ("roster_version", "o.roster_version"),
        ("version", "o.version"),
        ("course_code", "c.code"),
        ("term_code", "t.code"),
        ("branch", "g.branch"),
        ("semester", "g.semester"),
        ("section", "g.section"),
    ]
    expression = ",".join(f"'{key}',{value}" for key, value in fields)
    await check_cursor(
        conn,
        cursor,
        """SELECT 1 FROM app.course_enrollments e JOIN app.students s
        ON s.institute_id=e.institute_id AND s.id=e.student_id
        WHERE e.institute_id=:i AND s.auth_user_id=:a AND e.id=CAST(:cur AS uuid)""",
        {"i": institute, "a": actor},
    )
    rows = await many(
        conn,
        f"""SELECT e.id,e.offering_id,e.student_id,e.status,e.version,e.reason,
        jsonb_build_object({expression}) AS offering FROM app.course_enrollments e
        JOIN app.students s ON s.institute_id=e.institute_id AND s.id=e.student_id
        JOIN app.offerings o ON o.institute_id=e.institute_id AND o.id=e.offering_id
        {OFFERING_JOINS}
        WHERE e.institute_id=:i AND s.auth_user_id=:a AND s.status='approved'
        AND (CAST(:cursor AS uuid) IS NULL OR (e.created_at,e.id)<(SELECT created_at,id
          FROM app.course_enrollments WHERE institute_id=:i AND id=CAST(:cursor AS uuid)))
        ORDER BY e.created_at DESC,e.id DESC LIMIT :limit""",
        {"i": institute, "a": actor, "cursor": cursor, "limit": limit + 1},
    )
    return page(rows, limit)
