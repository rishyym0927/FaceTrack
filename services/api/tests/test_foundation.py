import asyncio
import json
from types import SimpleNamespace
from uuid import UUID

import jwt
import pytest
from sqlalchemy import text

from app import auth as auth_module
from app.db import context, make_engine
from app.main import create_app
from tools.seed import connect, seed


async def new_code(b, *, key="create-code", version=1):
    r = await b.client.post(
        f"/v1/offerings/{b.ids['offering']}/join-code", headers=b.headers(key=key, version=version)
    )
    assert r.status_code == 201, r.text
    return r.json()


async def request(b, code, *, label="student1", key="request"):
    return await b.client.post(
        "/v1/enrollment-requests", headers=b.headers(label, key=key), json={"join_code": code}
    )


async def test_health_auth_and_validation(backend):
    b = backend
    live = await b.client.get("/health/live")
    assert live.status_code == 200
    assert live.headers["cache-control"] == "no-store"
    assert live.headers["x-content-type-options"] == "nosniff"
    assert live.headers["x-frame-options"] == "DENY"
    assert live.headers["referrer-policy"] == "no-referrer"
    assert live.headers["permissions-policy"] == "camera=(), microphone=(), geolocation=()"
    ready = await b.client.get("/health/ready")
    assert ready.status_code == 200, ready.text
    assert (await b.client.get("/v1/me")).status_code == 401
    for changes in [
        {"exp": 1},
        {"aud": "another-project"},
        {"iss": "https://wrong.invalid"},
        {"sub": "not-a-uuid"},
        {"role": "service_role"},
        {"is_anonymous": True},
    ]:
        r = await b.client.get("/v1/me", headers=b.headers(**changes))
        assert r.status_code == 401
        assert "request_id" in r.json()["error"]
    bad = jwt.encode({"sub": b.users["teacher"]["id"]}, "x" * 32, algorithm="HS256")
    assert (
        await b.client.get("/v1/me", headers={"Authorization": "Bearer " + bad})
    ).status_code == 401
    r = await b.client.post(
        "/v1/identity/claim",
        headers=b.headers("student1"),
        json={"enrollment_number": "0001", "role": "admin"},
    )
    assert r.status_code == 422 and "input" not in r.text
    assert (await b.client.get("/v1/offerings?limit=201", headers=b.headers())).status_code == 422

    oversized = await b.client.post(
        "/v1/identity/claim",
        content=b"x" * (1024 * 1024 + 1),
        headers={"content-type": "application/json"},
    )
    assert oversized.status_code == 413
    assert oversized.json()["error"]["code"] == "BODY_TOO_LARGE"
    assert oversized.headers["cache-control"] == "no-store"
    assert oversized.headers["x-frame-options"] == "DENY"


async def test_claim_live_confirmed_email_and_no_role_escalation(backend):
    b = backend
    b.state["confirmed"] = False
    r = await b.claim(user_metadata={"email_verified": True, "role": "admin"})
    assert r.status_code == 403
    b.state["confirmed"] = True
    assert (await b.claim("student2", "0001")).status_code == 404
    assert (await b.claim()).status_code == 201
    assert (await b.claim()).status_code == 201  # same key converges
    own = (await b.client.get("/v1/me", headers=b.headers("student1"))).json()
    assert {m["role"] for m in own["memberships"]} == {"student"}
    assert [s["enrollment_number"] for s in own["students"]] == ["0001"]
    assert (
        await b.client.get("/v1/academics/courses", headers=b.headers("student1"))
    ).status_code == 403
    assert (await b.claim("student1", "0002")).status_code == 409  # different body, same key
    with connect(b.urls["owner"]) as conn:
        assert (
            conn.execute(
                "SELECT count(*) FROM app.memberships WHERE auth_user_id=%s",
                (b.users["student1"]["id"],),
            ).fetchone()[0]
            == 1
        )


async def test_provider_unavailable_is_not_authenticated(backend):
    backend.state["outage"] = True
    assert (await backend.client.get("/v1/me", headers=backend.headers())).status_code == 503


async def test_first_valid_token_loads_jwks_during_first_30_seconds(backend, monkeypatch):
    monkeypatch.setattr(auth_module, "time", SimpleNamespace(monotonic=lambda: 5.0))
    result = await backend.client.get("/v1/me", headers=backend.headers())
    assert result.status_code == 200, result.text


async def test_full_join_approval_and_confidentiality(backend):
    b = backend
    assert (await b.claim()).status_code == 201
    code = await new_code(b)
    response = await request(b, code["code"])
    assert response.status_code == 201, response.text
    enrollment = response.json()
    assert enrollment["status"] == "requested"
    replay = await request(b, code["code"])
    assert replay.json() == enrollment
    roster_url = f"/v1/offerings/{b.ids['offering']}/roster"
    assert (await b.client.get(roster_url, headers=b.headers("student1"))).status_code == 404
    assert (await b.client.get(roster_url, headers=b.headers("unassigned"))).status_code == 404
    roster = (await b.client.get(roster_url, headers=b.headers())).json()
    assert len(roster["items"]) == 1 and roster["items"][0]["status"] == "requested"
    review = f"/v1/offerings/{b.ids['offering']}/enrollments/{enrollment['id']}"
    result = await b.client.patch(
        review,
        headers=b.headers(version=1, key="approve"),
        json={"status": "active", "reason": "Approved roster verification"},
    )
    assert result.status_code == 200, result.text
    assert result.json()["status"] == "active" and result.json()["version"] == 2
    stale = await b.client.patch(
        review,
        headers=b.headers(version=1, key="stale"),
        json={"status": "withdrawn", "reason": "Stale review"},
    )
    assert stale.status_code == 409
    assert (await b.client.get("/v1/offerings", headers=b.headers("student1"))).json()["items"][0][
        "id"
    ] == b.ids["offering"]
    with connect(b.urls["owner"]) as conn:
        idem = conn.execute("SELECT response_json FROM app.idempotency_records").fetchall()
        stored = conn.execute("SELECT ciphertext FROM app.offering_join_codes").fetchone()[0]
        assert code["code"] not in json.dumps(idem)
        assert code["code"].encode() not in stored
        assert conn.execute("SELECT count(*) FROM app.course_enrollments").fetchone()[0] == 1


async def test_code_rotation_expiry_and_replay(backend):
    b = backend
    await b.claim()
    first = await new_code(b)
    same = await new_code(b)
    assert first == same
    second = await new_code(b, key="rotate-again", version=2)
    assert first["code"] != second["code"]
    assert (await request(b, first["code"])).status_code == 404
    stale_replay = await b.client.post(
        f"/v1/offerings/{b.ids['offering']}/join-code",
        headers=b.headers(key="create-code", version=1),
    )
    assert stale_replay.status_code == 409
    with connect(b.urls["owner"]) as conn:
        conn.execute(
            "UPDATE app.offering_join_codes SET expires_at=now()-interval '1 second' WHERE id=%s",
            (second["id"],),
        )
    assert (await request(b, second["code"], key="expired")).status_code == 404


async def test_invalid_code_limits_survive_error_rollbacks(backend):
    b = backend
    await b.claim()
    for i in range(10):
        assert (await request(b, "INVALID", key=f"failure-{i}")).status_code == 404
    assert (await request(b, "INVALID", key="failure-11")).status_code == 429
    with connect(b.urls["owner"]) as conn:
        assert conn.execute("SELECT attempts FROM app.rate_limit_windows").fetchone()[0] == 11
        assert conn.execute("SELECT count(*) FROM app.course_enrollments").fetchone()[0] == 0


async def test_membership_suspension_and_cross_tenant_access(backend):
    b = backend
    for label, inst, resource in [
        ("teacher", "other_institute", "other_offering"),
        ("other_teacher", "institute", "offering"),
    ]:
        r = await b.client.get(
            f"/v1/offerings/{b.ids[resource]}", headers=b.headers(label, institute=b.ids[inst])
        )
        assert r.status_code == 403
    with connect(b.urls["owner"]) as conn:
        conn.execute(
            "UPDATE app.memberships SET status='suspended' WHERE auth_user_id=%s",
            (b.users["teacher"]["id"],),
        )
    assert (await b.client.get("/v1/offerings", headers=b.headers())).status_code == 403


async def test_concurrent_claim_and_enrolment_requests(backend):
    b = backend
    results = await asyncio.gather(b.claim(key="claim-a"), b.claim(key="claim-b"))
    assert [r.status_code for r in results] == [201, 201]
    code = await new_code(b)
    results = await asyncio.gather(
        request(b, code["code"], key="a"), request(b, code["code"], key="b")
    )
    assert [r.status_code for r in results] == [201, 201]
    assert results[0].json()["id"] == results[1].json()["id"]


async def test_runtime_rls_constraints_and_pool_context_reset(backend):
    b = backend
    engine = make_engine(b.urls["runtime"])
    actor = UUID(b.users["teacher"]["id"])
    async with engine.connect() as conn:
        async with conn.begin():
            await context(conn, actor, UUID(b.ids["institute"]))
            assert len((await conn.execute(text("SELECT id FROM app.offerings"))).all()) == 1
            # Forging the tenant context alone does not create a membership in it.
            await context(conn, actor, UUID(b.ids["other_institute"]))
            assert (await conn.execute(text("SELECT id FROM app.offerings"))).all() == []
        async with conn.begin():
            assert (await conn.execute(text("SELECT id FROM app.offerings"))).all() == []
    await engine.dispose()
    with connect(b.urls["owner"]) as conn:
        with pytest.raises(Exception):
            conn.execute(
                """INSERT INTO app.offerings(institute_id,course_id,term_id,class_group_id,title)
                VALUES (%s,%s,%s,%s,'Invalid cross-tenant course')""",
                (b.ids["institute"], b.ids["other_course"], b.ids["term"], b.ids["extra_group"]),
            )


async def test_offering_creation_idempotence_and_term_integrity(backend):
    b = backend
    body = {
        "course_id": b.ids["extra_course"],
        "term_id": b.ids["term"],
        "class_group_id": b.ids["extra_group"],
    }
    first = await b.client.post("/v1/offerings", headers=b.headers(key="new"), json=body)
    assert first.status_code == 201, first.text
    second = await b.client.post("/v1/offerings", headers=b.headers(key="new"), json=body)
    assert first.json() == second.json()
    assert (
        await b.client.get(f"/v1/offerings/{first.json()['id']}", headers=b.headers())
    ).status_code == 200
    invalid = {**body, "term_id": b.ids["other_term"]}
    assert (
        await b.client.post("/v1/offerings", headers=b.headers(key="invalid"), json=invalid)
    ).status_code == 422
    assert (
        await b.client.post(
            "/v1/offerings",
            headers=b.headers("unassigned", key="spoof"),
            json={**body, "teacher_id": b.ids["teacher_profile"]},
        )
    ).status_code == 422


async def test_seed_repeat_and_readiness_rejects_owner(backend):
    b = backend
    with connect(b.urls["owner"]) as conn:
        seed(conn, b.users)
        assert conn.execute("SELECT count(*) FROM app.offerings").fetchone()[0] == 2
    unsafe = b.settings.model_copy(
        update={"database_url": __import__("pydantic").SecretStr(b.urls["owner"])}
    )
    app = create_app(unsafe)
    import httpx

    async with app.router.lifespan_context(app):
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app), base_url="http://test"
        ) as client:
            assert (await client.get("/health/ready")).status_code == 503


async def test_payload_limits_and_error_scrubbing(backend):
    b = backend
    r = await b.client.post(
        "/v1/identity/claim", content=b"x" * (1024 * 1024 + 1), headers=b.headers("student1")
    )
    assert r.status_code == 413
    r = await b.client.post(
        "/v1/identity/claim", json={"enrollment_number": "x" * 1000}, headers=b.headers("student1")
    )
    assert r.status_code == 422 and "x" * 100 not in r.text
    assert "ciphertext" not in json.dumps(b.app.openapi())
    assert "face_templates" not in json.dumps(b.app.openapi())


async def test_current_code_reauthorization_and_no_student_catalogue(backend):
    b = backend
    await b.claim()
    assert (await b.client.get("/v1/offerings", headers=b.headers("student1"))).json()[
        "items"
    ] == []
    code = await new_code(b)
    url = f"/v1/offerings/{b.ids['offering']}/join-code"
    assert (await b.client.get(url, headers=b.headers())).json() == code
    for who in ("student1", "unassigned"):
        assert (await b.client.get(url, headers=b.headers(who))).status_code == 404
    with connect(b.urls["owner"]) as conn:
        conn.execute(
            "UPDATE app.offering_teachers SET status='inactive' WHERE offering_id=%s",
            (b.ids["offering"],),
        )
    assert (await b.client.get(url, headers=b.headers())).status_code == 404
    assert (
        await b.client.post(url, headers=b.headers(key="create-code", version=1))
    ).status_code == 404


async def test_database_cannot_grant_self_teacher_and_retains_history(backend):
    b = backend
    await b.claim()
    engine = make_engine(b.urls["runtime"])
    from sqlalchemy.exc import DBAPIError

    try:
        async with engine.connect() as conn:
            with pytest.raises(DBAPIError):
                async with conn.begin():
                    await context(conn, UUID(b.users["student1"]["id"]), UUID(b.ids["institute"]))
                    await conn.execute(
                        text(
                            "INSERT INTO app.memberships(institute_id,auth_user_id,role) VALUES (:i,:a,'teacher')"
                        ),
                        {"i": UUID(b.ids["institute"]), "a": UUID(b.users["student1"]["id"])},
                    )
            with pytest.raises(DBAPIError):
                async with conn.begin():
                    await context(conn, UUID(b.users["teacher"]["id"]), UUID(b.ids["institute"]))
                    await conn.execute(text("DELETE FROM app.students"))
    finally:
        await engine.dispose()


async def test_suspended_student_cannot_replay_claim_and_cors_is_exact(backend):
    b = backend
    await b.claim()
    with connect(b.urls["owner"]) as conn:
        conn.execute(
            "UPDATE app.memberships SET status='suspended' WHERE auth_user_id=%s",
            (b.users["student1"]["id"],),
        )
    assert (await b.claim()).status_code == 403
    response = await b.client.options(
        "/v1/me",
        headers={"Origin": "https://untrusted.invalid", "Access-Control-Request-Method": "GET"},
    )
    assert response.status_code == 400 and "access-control-allow-origin" not in response.headers


async def test_teacher_assignment_and_term_constraints_in_database(backend):
    b = backend
    from datetime import date, timedelta
    from uuid import uuid4

    import psycopg

    with connect(b.urls["owner"]) as conn:
        conn.execute(
            "UPDATE app.memberships SET status='suspended' WHERE auth_user_id=%s",
            (b.users["unassigned"]["id"],),
        )
        with pytest.raises(psycopg.errors.CheckViolation), conn.transaction():
            conn.execute(
                "INSERT INTO app.offering_teachers(institute_id,offering_id,teacher_id) VALUES (%s,%s,%s)",
                (b.ids["institute"], b.ids["offering"], b.ids["unassigned_profile"]),
            )
        new_term = uuid4()
        conn.execute(
            "INSERT INTO app.terms(id,institute_id,code,starts_on,ends_on) VALUES (%s,%s,%s,%s,%s)",
            (
                new_term,
                b.ids["institute"],
                "OTHER-TERM",
                date.today(),
                date.today() + timedelta(days=30),
            ),
        )
        with pytest.raises(psycopg.errors.ForeignKeyViolation), conn.transaction():
            conn.execute(
                "INSERT INTO app.offerings(institute_id,course_id,term_id,class_group_id,title) VALUES (%s,%s,%s,%s,'Wrong term')",
                (b.ids["institute"], b.ids["extra_course"], new_term, b.ids["extra_group"]),
            )


async def test_tampered_signature_and_unknown_key_are_rejected(backend):
    b = backend
    from cryptography.hazmat.primitives.asymmetric import ec

    claims = jwt.decode(b.token(), options={"verify_signature": False})
    bad = jwt.encode(
        claims,
        ec.generate_private_key(ec.SECP256R1()),
        algorithm="ES256",
        headers={"kid": "fixture-key"},
    )
    assert (
        await b.client.get("/v1/me", headers={"Authorization": "Bearer " + bad})
    ).status_code == 401
    bad = jwt.encode(
        claims,
        ec.generate_private_key(ec.SECP256R1()),
        algorithm="ES256",
        headers={"kid": "not-in-jwks"},
    )
    assert (
        await b.client.get("/v1/me", headers={"Authorization": "Bearer " + bad})
    ).status_code == 401


async def test_admin_assigns_other_approved_faculty_without_exposing_memberships(backend):
    b = backend
    from tools.seed import uid

    with connect(b.urls["owner"]) as conn:
        conn.execute(
            "INSERT INTO app.memberships(id,institute_id,auth_user_id,role) VALUES (%s,%s,%s,'admin')",
            (uid("admin-fixture"), b.ids["institute"], b.users["teacher"]["id"]),
        )
    body = {
        "course_id": b.ids["extra_course"],
        "term_id": b.ids["term"],
        "class_group_id": b.ids["extra_group"],
        "teacher_id": b.ids["unassigned_profile"],
    }
    result = await b.client.post("/v1/offerings", headers=b.headers(key="admin-create"), json=body)
    assert result.status_code == 201, result.text
    assert (
        await b.client.get(f"/v1/offerings/{result.json()['id']}", headers=b.headers("unassigned"))
    ).status_code == 200
    own = (await b.client.get("/v1/me", headers=b.headers("unassigned"))).json()
    assert all(m["role"] == "teacher" for m in own["memberships"])


def test_empty_migrations_revoke_inherited_client_grants(backend):
    # This is synchronous test code; backend fixture still guards the managed cluster.
    b = backend
    import os
    import subprocess
    import sys
    from pathlib import Path
    from uuid import uuid4

    from psycopg import sql
    from sqlalchemy import make_url

    name = "facetrack_verify_" + uuid4().hex[:12]
    base = make_url(b.urls["owner"])
    with connect(b.urls["owner"]) as conn:
        conn.autocommit = True
        for role in ("anon", "authenticated", "service_role"):
            if not conn.execute("SELECT 1 FROM pg_roles WHERE rolname=%s", (role,)).fetchone():
                conn.execute(sql.SQL("CREATE ROLE {} NOLOGIN").format(sql.Identifier(role)))
        conn.execute(
            sql.SQL("CREATE DATABASE {} OWNER facetrack_owner").format(sql.Identifier(name))
        )
    target = base.set(database=name).render_as_string(hide_password=False)
    try:
        with connect(target) as conn:
            conn.execute("CREATE SCHEMA auth")
            conn.execute("CREATE TABLE auth.users(id uuid PRIMARY KEY)")
            for role in ("anon", "authenticated", "service_role"):
                conn.execute(
                    sql.SQL("ALTER DEFAULT PRIVILEGES GRANT ALL ON TABLES TO {}").format(
                        sql.Identifier(role)
                    )
                )
                conn.execute(
                    sql.SQL("ALTER DEFAULT PRIVILEGES GRANT ALL ON FUNCTIONS TO {}").format(
                        sql.Identifier(role)
                    )
                )
        api = Path(__file__).resolve().parents[1]
        result = subprocess.run(
            [sys.executable, "-m", "alembic", "upgrade", "head"],
            cwd=api,
            env={**os.environ, "MIGRATION_DATABASE_URL": target},
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0, result.stderr
        with connect(target) as conn:
            assert (
                conn.execute(
                    "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='app' AND c.relkind='r' AND c.relrowsecurity AND c.relforcerowsecurity"
                ).fetchone()[0]
                == 37
            )
            for role in ("anon", "authenticated", "service_role"):
                assert not conn.execute(
                    "SELECT has_table_privilege(%s,'app.students','SELECT')", (role,)
                ).fetchone()[0]
                assert not conn.execute(
                    "SELECT has_function_privilege(%s,'app.actor_id()','EXECUTE')", (role,)
                ).fetchone()[0]
    finally:
        with connect(b.urls["owner"]) as conn:
            conn.autocommit = True
            conn.execute(sql.SQL("DROP DATABASE {}").format(sql.Identifier(name)))


async def test_own_enrollment_history_is_scoped_and_labelled(backend):
    b = backend
    await b.claim()
    code = await new_code(b)
    enrollment = (await request(b, code["code"])).json()
    response = await b.client.get("/v1/me/enrollments", headers=b.headers("student1"))
    assert response.status_code == 200, response.text
    assert response.json()["items"][0]["status"] == "requested"
    assert response.json()["items"][0]["offering"]["branch"] == "CSE"
    await b.claim("student2", "0002")
    assert (await b.client.get("/v1/me/enrollments", headers=b.headers("student2"))).json()[
        "items"
    ] == []
    assert (await b.client.get("/v1/me/enrollments", headers=b.headers())).status_code == 403
    assert (
        await b.client.get(
            "/v1/me/enrollments", headers=b.headers("student1", institute=b.ids["other_institute"])
        )
    ).status_code == 403
    review = f"/v1/offerings/{b.ids['offering']}/enrollments/{enrollment['id']}"
    assert (
        await b.client.patch(
            review,
            headers=b.headers(version=1, key="reject"),
            json={"status": "rejected", "reason": "Not enrolled in this group"},
        )
    ).status_code == 200
    assert (await b.client.get("/v1/me/enrollments", headers=b.headers("student1"))).json()[
        "items"
    ][0]["status"] == "rejected"


async def test_roster_status_filter_applies_before_pagination(backend):
    b = backend
    await b.claim()
    code = await new_code(b)
    await request(b, code["code"])
    url = f"/v1/offerings/{b.ids['offering']}/roster"
    assert (
        len(
            (await b.client.get(url + "?status=requested&limit=1", headers=b.headers())).json()[
                "items"
            ]
        )
        == 1
    )
    assert (await b.client.get(url + "?status=active&limit=1", headers=b.headers())).json()[
        "items"
    ] == []
    assert (await b.client.get(url + "?status=invalid", headers=b.headers())).status_code == 422


async def test_teacher_work_summary_is_scoped_and_counts_requests(backend):
    b = backend
    await b.claim()
    code = await new_code(b)
    await request(b, code["code"])
    url = "/v1/teacher/work-summary"
    result = await b.client.get(url, headers=b.headers())
    assert result.status_code == 200, result.text
    assert result.headers["cache-control"] == "no-store"
    assert [(row["id"], row["join_requests"]) for row in result.json()["items"]] == [
        (b.ids["offering"], 1)
    ]
    assert (await b.client.get(url, headers=b.headers("student1"))).status_code == 403
    assert (await b.client.get(url, headers=b.headers("unassigned"))).json()["items"] == []
