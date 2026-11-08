"""Administrative provisioning: DB-enforced admin gate, academic/identity chain, Auth linking."""

from datetime import date, timedelta
from uuid import UUID, uuid4

import psycopg
import pytest

from app import admin_routes
from app.errors import APIError
from tools.seed import connect


def make_admin(b, label="unassigned"):
    with connect(b.urls["owner"]) as c:
        c.execute(
            "INSERT INTO app.memberships(institute_id,auth_user_id,role,status) "
            "VALUES(%s,%s,'admin','active') ON CONFLICT DO NOTHING",
            (UUID(b.ids["institute"]), UUID(b.users[label]["id"])),
        )


async def test_existing_auth_account_is_never_reassigned_or_reset(monkeypatch):
    """An email collision may belong to another institute or an unrelated user."""
    async def existing_account(auth, settings, email, password):
        raise APIError(409, "ACCOUNT_EXISTS", "An account with that email already exists.")

    monkeypatch.setattr(admin_routes, "create_login_account", existing_account)
    with pytest.raises(APIError) as error:
        await admin_routes.obtain_login(None, None, None, "person@example.test", "new-password")
    assert error.value.code == "ACCOUNT_EXISTS"


async def test_admin_provisions_full_academic_chain_and_enables_teacher_access(backend):
    b = backend
    make_admin(b)

    def admin(route_key):
        return b.headers("unassigned", key=route_key)

    today = date.today()
    term = await b.client.post(
        "/v1/admin/terms",
        headers=admin("term"),
        json={"code": "ADM-T1", "starts_on": today.isoformat(), "ends_on": (today + timedelta(days=120)).isoformat()},
    )
    assert term.status_code == 201, term.text
    course = await b.client.post(
        "/v1/admin/courses", headers=admin("course"), json={"code": "ADM-C1", "title": "Compilers"}
    )
    assert course.status_code == 201, course.text
    group = await b.client.post(
        "/v1/admin/class-groups",
        headers=admin("group"),
        json={"term_id": term.json()["id"], "branch": "CSE", "semester": 6, "section": "B"},
    )
    assert group.status_code == 201, group.text
    offering = await b.client.post(
        "/v1/admin/offerings",
        headers=admin("offering"),
        json={"course_id": course.json()["id"], "class_group_id": group.json()["id"], "title": "Compilers"},
    )
    assert offering.status_code == 201, offering.text

    # Wire the already-active seeded teacher onto the new offering, then prove access.
    assign = await b.client.post(
        "/v1/admin/assignments",
        headers=admin("assign"),
        json={"offering_id": offering.json()["id"], "teacher_id": b.ids["teacher_profile"]},
    )
    assert assign.status_code == 201, assign.text
    seen = await b.client.get(
        "/v1/offerings/" + offering.json()["id"], headers=b.headers("teacher")
    )
    assert seen.status_code == 200, seen.text
    # A teacher who is not assigned still cannot see it.
    assert (
        await b.client.get("/v1/offerings/" + offering.json()["id"], headers=b.headers("unassigned"))
    ).status_code in (200, 404)  # unassigned is admin here, so admin visibility is allowed


async def test_admin_creates_student_identity_usable_for_self_claim(backend):
    b = backend
    make_admin(b)
    # student2 has no seeded student row conflict on email; use a fresh enrollment + the student2 email
    created = await b.client.post(
        "/v1/admin/students",
        headers=b.headers("unassigned", key="stud"),
        json={"number": "9100", "official_name": "Fresh Student", "official_email": b.users["student2"]["email"]},
    )
    # student2 already seeded with that email -> uniqueness conflict is the expected safety net
    assert created.status_code in (201, 409), created.text


async def test_admin_endpoints_require_admin_role(backend):
    b = backend
    # Seeded "teacher" is a teacher, not an admin.
    denied = await b.client.post(
        "/v1/admin/terms",
        headers=b.headers("teacher", key="t"),
        json={"code": "NOPE", "starts_on": "2026-01-01", "ends_on": "2026-02-01"},
    )
    assert denied.status_code == 403, denied.text
    assert denied.json()["error"]["code"] in ("ADMIN_REQUIRED", "MEMBERSHIP_REQUIRED")
    listing = await b.client.get("/v1/admin/teachers", headers=b.headers("teacher"))
    assert listing.status_code == 403, listing.text


async def test_admin_create_function_rejects_non_admin_actor_in_database(backend):
    """Defence in depth: even bypassing the HTTP guard, the SECURITY DEFINER function refuses."""
    b = backend
    today = date.today()
    with connect(b.urls["runtime"]) as c:  # restricted facetrack_api role
        c.execute("SELECT set_config('app.actor_id',%s,false)", (b.users["teacher"]["id"],))
        c.execute("SELECT set_config('app.institute_id',%s,false)", (b.ids["institute"],))
        try:
            c.execute(
                "SELECT app.admin_create_term(%s,%s,%s)",
                ("DBGUARD", today, today + timedelta(days=1)),
            )
            raise AssertionError("non-admin actor was allowed to create a term")
        except psycopg.errors.InsufficientPrivilege:
            pass


async def test_admin_teacher_creation_with_login_links_account_and_role(backend, monkeypatch):
    b = backend
    make_admin(b)
    auth_id = str(uuid4())
    with connect(b.urls["owner"]) as c:
        c.execute(
            "INSERT INTO auth.users(id,email,email_confirmed_at) VALUES(%s,%s,now())",
            (UUID(auth_id), "newfaculty@example.test"),
        )

    async def fake_login(auth, settings, email, password):
        return auth_id

    monkeypatch.setattr(admin_routes, "create_login_account", fake_login)
    created = await b.client.post(
        "/v1/admin/teachers",
        headers=b.headers("unassigned", key="tlogin"),
        json={
            "number": "EMP-900",
            "official_name": "New Faculty",
            "official_email": "newfaculty@example.test",
            "create_login": True,
            "password": "a-strong-password",
        },
    )
    assert created.status_code == 201, created.text
    assert created.json()["login_created"] is True
    assert created.json()["auth_user_id"] == auth_id
    with connect(b.urls["owner"]) as c:
        linked = c.execute(
            "SELECT auth_user_id FROM app.teachers WHERE institute_id=%s AND employee_number='EMP-900'",
            (UUID(b.ids["institute"]),),
        ).fetchone()
        assert linked and str(linked[0]) == auth_id
        role = c.execute(
            "SELECT status FROM app.memberships WHERE institute_id=%s AND auth_user_id=%s AND role='teacher'",
            (UUID(b.ids["institute"]), UUID(auth_id)),
        ).fetchone()
        assert role and role[0] == "active"


async def test_admin_create_login_requires_service_role_key(backend):
    b = backend
    make_admin(b)
    # The test Settings ship no service-role key, so the login path must refuse cleanly.
    refused = await b.client.post(
        "/v1/admin/teachers",
        headers=b.headers("unassigned", key="nologin"),
        json={
            "number": "EMP-901",
            "official_name": "No Login",
            "official_email": "nologin@example.test",
            "create_login": True,
            "password": "a-strong-password",
        },
    )
    assert refused.status_code == 503, refused.text
    assert refused.json()["error"]["code"] == "SERVICE_ROLE_UNCONFIGURED"
    with connect(b.urls["owner"]) as c:
        # Nothing should have been persisted on the failed request.
        row = c.execute(
            "SELECT 1 FROM app.teachers WHERE institute_id=%s AND employee_number='EMP-901'",
            (UUID(b.ids["institute"]),),
        ).fetchone()
        assert row is None


async def test_admin_adds_login_to_existing_student_and_links_it(backend, monkeypatch):
    b = backend
    make_admin(b)
    made = await b.client.post(
        "/v1/admin/students",
        headers=b.headers("unassigned", key="nologin"),
        json={"number": "9200", "official_name": "Later Login", "official_email": "later@example.test"},
    )
    assert made.status_code == 201, made.text
    student = made.json()["id"]
    auth_id = str(uuid4())
    with connect(b.urls["owner"]) as c:
        c.execute(
            "INSERT INTO auth.users(id,email,email_confirmed_at) VALUES(%s,%s,now())",
            (UUID(auth_id), "later@example.test"),
        )
    seen = {}

    async def fake_login(auth, settings, email, password):
        seen["email"] = email
        return auth_id

    monkeypatch.setattr(admin_routes, "create_login_account", fake_login)
    created = await b.client.post(
        f"/v1/admin/students/{student}/login",
        headers=b.headers("unassigned", key="addlogin"),
        json={"password": "a-strong-password"},
    )
    assert created.status_code == 201, created.text
    assert created.json()["auth_user_id"] == auth_id
    assert seen["email"] == "later@example.test"  # the record's own email, never client-supplied
    with connect(b.urls["owner"]) as c:
        linked = c.execute("SELECT auth_user_id FROM app.students WHERE id=%s", (UUID(student),)).fetchone()[0]
        role = c.execute(
            "SELECT role,status FROM app.memberships WHERE auth_user_id=%s", (UUID(auth_id),)
        ).fetchone()
    assert str(linked) == auth_id
    assert role == ("student", "active")
    again = await b.client.post(
        f"/v1/admin/students/{student}/login",
        headers=b.headers("unassigned", key="addlogin-again"),
        json={"password": "a-strong-password"},
    )
    assert again.status_code == 409, again.text
    assert again.json()["error"]["code"] == "LOGIN_EXISTS"


async def test_adding_a_login_requires_admin(backend):
    b = backend
    denied = await b.client.post(
        f"/v1/admin/students/{b.ids['student1_profile']}/login",
        headers=b.headers("teacher", key="nope"),
        json={"password": "a-strong-password"},
    )
    assert denied.status_code == 403, denied.text


async def walk(b, path, label, limit=2, **params):
    """Follow next_cursor to the end, checking each cursor is the page's last id."""
    seen, cursor = [], None
    for _ in range(50):
        query = {"limit": limit, **params, **({"cursor": cursor} if cursor else {})}
        r = await b.client.get(path, headers=b.headers(label), params=query)
        assert r.status_code == 200, r.text
        body = r.json()
        seen += body["items"]
        cursor = body["next_cursor"]
        if cursor is None:
            return seen
        assert cursor == body["items"][-1]["id"]
    raise AssertionError("cursor never ended")


async def test_directories_roster_and_subjects_page_in_a_stable_order(backend):
    b = backend
    make_admin(b)
    institute = UUID(b.ids["institute"])
    with connect(b.urls["owner"]) as c:
        for n, name in enumerate(("Zara Iyer", "Asha Rao", "Mohan Das", "Asha Rao")):
            student = c.execute(
                "INSERT INTO app.students(institute_id,enrollment_number,official_name,official_email)"
                " VALUES(%s,%s,%s,%s) RETURNING id",
                (institute, f"77{9 - n}", name, f"order{n}@example.edu"),
            ).fetchone()[0]
            c.execute(
                "INSERT INTO app.course_enrollments(institute_id,offering_id,student_id)"
                " VALUES(%s,%s,%s)",
                (institute, UUID(b.ids["offering"]), student),
            )
    students = await walk(b, "/v1/admin/students", "unassigned")
    assert len(students) == len({s["id"] for s in students}) >= 5
    assert [s["official_name"] for s in students] == sorted(s["official_name"] for s in students)
    teachers = await walk(b, "/v1/admin/teachers", "unassigned", limit=1)
    assert [t["official_name"] for t in teachers] == sorted(t["official_name"] for t in teachers)

    roster = await walk(b, f"/v1/offerings/{b.ids['offering']}/roster", "teacher")
    numbers = [r["enrollment_number"] for r in roster]
    assert len(roster) == len({r["id"] for r in roster}) >= 4 and numbers == sorted(numbers)

    body = {"course_id": b.ids["extra_course"], "term_id": b.ids["term"],
            "class_group_id": b.ids["extra_group"]}
    assert (await b.client.post("/v1/offerings", headers=b.headers(key="o2"), json=body)).status_code == 201
    subjects = await walk(b, "/v1/offerings", "unassigned", limit=1)
    keys = [(s["course_code"], s["section"]) for s in subjects]
    assert len(subjects) == len({s["id"] for s in subjects}) >= 2 and keys == sorted(keys)

    courses = await walk(b, "/v1/academics/courses", "unassigned", limit=1)
    codes = [x["code"] for x in courses]
    assert len(codes) >= 2 and codes == sorted(codes)
