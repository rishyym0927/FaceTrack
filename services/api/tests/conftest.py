"""Real private PostgreSQL; synthetic signed JWTs and an explicitly mocked Auth provider."""

import json
import os
import sys
import time
from pathlib import Path
from types import SimpleNamespace
from uuid import UUID

import httpx
import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import ec
from sqlalchemy import make_url

sys.path.insert(0, str(Path(__file__).parents[1]))
from app.config import Settings  # noqa: E402
from app.main import create_app  # noqa: E402
from tools.seed import connect, seed, uid  # noqa: E402

ROOT = Path(__file__).resolve().parents[3]


@pytest.fixture
async def backend():
    path = ROOT / ".local/backend/connections.json"
    if not path.exists():
        pytest.fail("Run the documented private local_db.py start before backend tests.")
    urls = json.loads(path.read_text())["test"]
    owner_url = make_url(urls["owner"])
    # Never truncate a remotely configured database, even if an operator exported unrelated URLs.
    assert owner_url.database == "facetrack_test"
    if os.name == "nt":
        assert owner_url.host in {"127.0.0.1", "localhost"}
        assert owner_url.port == 55432
    else:
        assert Path(owner_url.query["host"]).resolve() == ROOT / ".local/backend/socket"
    labels = ["teacher", "unassigned", "other_teacher", "student1", "student2", "other_student"]
    users = {
        label: {"id": str(uid("user:" + label)), "email": label + "@example.test"}
        for label in labels
    }
    with connect(urls["owner"]) as conn:
        conn.execute(
            "TRUNCATE "
            + ",".join(
                "app." + row[0]
                for row in conn.execute(
                    "SELECT tablename FROM pg_tables WHERE schemaname='app'"
                ).fetchall()
            )
            + ", auth.users CASCADE"
        )
        for user in users.values():
            conn.execute(
                "INSERT INTO auth.users(id,email,email_confirmed_at) VALUES (%s,%s,now())",
                (UUID(user["id"]), user["email"]),
            )
        ids = seed(conn, users)
    private_key = ec.generate_private_key(ec.SECP256R1())
    public = jwt.algorithms.ECAlgorithm.to_jwk(private_key.public_key(), as_dict=True)
    public.update(kid="fixture-key", alg="ES256", use="sig")
    settings = Settings(
        _env_file=None,
        database_url=urls["runtime"],
        supabase_url="https://foundation.supabase.invalid",
        supabase_publishable_key="fixture-public-key",
        join_code_keys={"v1": "12" * 32},
    )
    state = {"outage": False, "confirmed": True, "email_override": None}

    def token(label="teacher", **overrides):
        claims = {
            "sub": users[label]["id"],
            "iss": settings.supabase_url + "/auth/v1",
            "aud": "authenticated",
            "role": "authenticated",
            "iat": int(time.time()),
            "exp": int(time.time()) + 3600,
            **overrides,
        }
        return jwt.encode(claims, private_key, algorithm="ES256", headers={"kid": "fixture-key"})

    def provider(request):
        if state["outage"]:
            return httpx.Response(503)
        if request.url.path.endswith("jwks.json"):
            return httpx.Response(200, json={"keys": [public]})
        if request.url.path.endswith("/user"):
            claims = jwt.decode(
                request.headers["authorization"].split()[1],
                private_key.public_key(),
                algorithms=["ES256"],
                audience="authenticated",
            )
            user = next(u for u in users.values() if u["id"] == claims["sub"])
            return httpx.Response(
                200,
                json={
                    "id": user["id"],
                    "email": state["email_override"] or user["email"],
                    "email_confirmed_at": "2026-10-22T00:00:00Z" if state["confirmed"] else None,
                },
            )
        return httpx.Response(404)

    app = create_app(settings, auth_transport=httpx.MockTransport(provider))
    async with app.router.lifespan_context(app):
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app), base_url="http://test"
        ) as client:

            def headers(
                label="teacher", *, institute=None, version=None, key="fixture-key", **claims
            ):
                result = {
                    "Authorization": "Bearer " + token(label, **claims),
                    "X-Institute-ID": institute or ids["institute"],
                    "Idempotency-Key": key,
                }
                if version is not None:
                    result["If-Match"] = str(version)
                return result

            async def claim(label="student1", enrollment="0001", **kwargs):
                return await client.post(
                    "/v1/identity/claim",
                    headers=headers(label, **kwargs),
                    json={"enrollment_number": enrollment},
                )

            yield SimpleNamespace(
                client=client,
                app=app,
                settings=settings,
                ids=ids,
                users=users,
                urls=urls,
                headers=headers,
                token=token,
                state=state,
                claim=claim,
            )
