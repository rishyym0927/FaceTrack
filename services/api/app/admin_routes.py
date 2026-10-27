"""Administrative provisioning endpoints.

Every write runs through an app.admin_* SECURITY DEFINER function that re-checks
app.is_admin() in the database, so the HTTP layer's require_admin() is defence in
depth rather than the only gate. Creating an actual login account is optional and
needs SUPABASE_SERVICE_ROLE_KEY; without it the identity/role endpoints still work.
"""

from datetime import date
from typing import Annotated, Literal
from uuid import UUID

import httpx
from fastapi import Depends, Header, Query, Request
from pydantic import Field, model_validator

from .db import many, one, transaction
from .errors import APIError
from .schemas import Strict
from .security import idempotent, roles
from .security import remember as remember_effect


async def require_admin(conn, actor, institute):
    if "admin" not in await roles(conn, actor, institute):
        raise APIError(403, "ADMIN_REQUIRED", "Administrator role is required.")


async def create_login_account(auth, settings, email: str, password: str) -> str:
    """Provision a confirmed Supabase Auth account via the service-role admin API."""
    key = settings.supabase_service_role_key.get_secret_value()
    if not key:
        raise APIError(
            503,
            "SERVICE_ROLE_UNCONFIGURED",
            "Login-account creation is unavailable: SUPABASE_SERVICE_ROLE_KEY is not configured.",
        )
    try:
        response = await auth.client.post(
            settings.supabase_url + "/auth/v1/admin/users",
            headers={"Authorization": "Bearer " + key, "apikey": key},
            json={"email": email, "password": password, "email_confirm": True},
        )
    except httpx.HTTPError as exc:
        raise APIError(
            503, "AUTH_PROVISION_FAILED", "Could not reach the authentication provider.", retryable=True
        ) from exc
    if response.status_code in (200, 201):
        try:
            return str(UUID(response.json()["id"]))
        except (ValueError, KeyError, TypeError) as exc:
            raise APIError(503, "AUTH_PROVISION_FAILED", "Unexpected provider response.") from exc
    if response.status_code in (409, 422):
        raise APIError(409, "ACCOUNT_EXISTS", "An account with that email already exists.")
    raise APIError(503, "AUTH_PROVISION_FAILED", "The authentication provider rejected the request.")


class TermCreate(Strict):
    code: str = Field(min_length=1, max_length=32)
    starts_on: date
    ends_on: date

    @model_validator(mode="after")
    def ordered(self):
        if self.ends_on < self.starts_on:
            raise ValueError("ends_on must not precede starts_on")
        return self


class CourseCreate(Strict):
    code: str = Field(min_length=1, max_length=32)
    title: str = Field(min_length=1, max_length=150)


class GroupCreate(Strict):
    term_id: UUID
    branch: str = Field(min_length=1, max_length=50)
    semester: int = Field(ge=1, le=20)
    section: str = Field(min_length=1, max_length=32)


class OfferingCreate(Strict):
    course_id: UUID
    class_group_id: UUID
    title: str = Field(min_length=1, max_length=150)


class IdentityCreate(Strict):
    number: str = Field(min_length=1, max_length=32)
    official_name: str = Field(min_length=1, max_length=100)
    official_email: str = Field(min_length=3, max_length=254)
    create_login: bool = False
    password: str | None = Field(default=None, min_length=8, max_length=128)

    @model_validator(mode="after")
    def login_needs_password(self):
        if "@" not in self.official_email:
            raise ValueError("official_email must be an email address")
        if self.create_login and not self.password:
            raise ValueError("password is required when create_login is true")
        return self


class LoginCreate(Strict):
    password: str = Field(min_length=8, max_length=128)


class RoleGrant(Strict):
    auth_user_id: UUID
    role: Literal["student", "teacher", "admin"]
    status: Literal["active", "suspended", "pending"] = "active"


class Assignment(Strict):
    offering_id: UUID
    teacher_id: UUID
    can_finalize: bool = True


def install(app, engine, settings, principal, storage, auth):
    User = Annotated[object, Depends(principal)]
    Institute = Annotated[UUID, Header(alias="X-Institute-ID")]
    Key = Annotated[str, Header(alias="Idempotency-Key", min_length=1, max_length=128)]
    Limit = Annotated[int, Query(ge=1, le=200)]

    async def provision(request, user, institute, body, key, call):
        """Shared idempotent admin write: authorize, run `call(conn)`, remember the result."""
        async with transaction(engine, user.user_id, institute) as conn:
            await require_admin(conn, user.user_id, institute)
            route = request.url.path
            payload = {k: v for k, v in body.model_dump().items() if k != "password"}
            cached, fp = await idempotent(conn, user.user_id, institute, route, key, payload)
            if cached:
                return cached
            result = await call(conn)
            await remember_effect(conn, user.user_id, institute, route, key, fp, result)
            return result

    @app.get("/v1/admin/teachers")
    async def list_teachers(user: User, institute_id: Institute, limit: Limit = 200):
        async with transaction(engine, user.user_id, institute_id) as conn:
            await require_admin(conn, user.user_id, institute_id)
            return {
                "items": [
                    dict(row)
                    for row in await many(
                        conn,
                        """SELECT id,auth_user_id,employee_number,official_name,official_email,status
                        FROM app.teachers WHERE institute_id=:i ORDER BY official_name LIMIT :n""",
                        {"i": institute_id, "n": limit},
                    )
                ]
            }

    @app.get("/v1/admin/students")
    async def list_students(user: User, institute_id: Institute, limit: Limit = 200):
        async with transaction(engine, user.user_id, institute_id) as conn:
            await require_admin(conn, user.user_id, institute_id)
            return {
                "items": [
                    dict(row)
                    for row in await many(
                        conn,
                        """SELECT id,auth_user_id,enrollment_number,official_name,official_email,status
                        FROM app.students WHERE institute_id=:i ORDER BY official_name LIMIT :n""",
                        {"i": institute_id, "n": limit},
                    )
                ]
            }

    @app.post("/v1/admin/terms", status_code=201)
    async def create_term(body: TermCreate, request: Request, user: User, institute_id: Institute, key: Key):
        async def call(conn):
            row = await one(
                conn,
                "SELECT app.admin_create_term(:c,:s,:e) AS id",
                {"c": body.code, "s": body.starts_on, "e": body.ends_on},
            )
            return {"id": str(row["id"])}

        return await provision(request, user, institute_id, body, key, call)

    @app.post("/v1/admin/courses", status_code=201)
    async def create_course(body: CourseCreate, request: Request, user: User, institute_id: Institute, key: Key):
        async def call(conn):
            row = await one(
                conn, "SELECT app.admin_create_course(:c,:t) AS id", {"c": body.code, "t": body.title}
            )
            return {"id": str(row["id"])}

        return await provision(request, user, institute_id, body, key, call)

    @app.post("/v1/admin/class-groups", status_code=201)
    async def create_group(body: GroupCreate, request: Request, user: User, institute_id: Institute, key: Key):
        async def call(conn):
            row = await one(
                conn,
                "SELECT app.admin_create_class_group(:t,:b,:s,:sec) AS id",
                {"t": str(body.term_id), "b": body.branch, "s": body.semester, "sec": body.section},
            )
            return {"id": str(row["id"])}

        return await provision(request, user, institute_id, body, key, call)

    @app.post("/v1/admin/offerings", status_code=201)
    async def create_offering(body: OfferingCreate, request: Request, user: User, institute_id: Institute, key: Key):
        async def call(conn):
            row = await one(
                conn,
                "SELECT app.admin_create_offering(:c,:g,:t) AS id",
                {"c": str(body.course_id), "g": str(body.class_group_id), "t": body.title},
            )
            return {"id": str(row["id"])}

        return await provision(request, user, institute_id, body, key, call)

    @app.post("/v1/admin/teachers", status_code=201)
    async def create_teacher(body: IdentityCreate, request: Request, user: User, institute_id: Institute, key: Key):
        return await provision(
            request, user, institute_id, body, key, _identity_call(body, "teacher", auth, settings)
        )

    @app.post("/v1/admin/students", status_code=201)
    async def create_student(body: IdentityCreate, request: Request, user: User, institute_id: Institute, key: Key):
        return await provision(
            request, user, institute_id, body, key, _identity_call(body, "student", auth, settings)
        )

    async def add_login(kind, identity_id, body, request, user, institute_id, key):
        """Give an existing faculty or student record a login account, then link it."""
        table, role = {"teacher": ("teachers", "teacher"), "student": ("students", "student")}[kind]

        async def call(conn):
            row = await one(
                conn,
                # Lock the row so a concurrent request waits, then sees the link and gets 409.
                f"SELECT official_email,auth_user_id FROM app.{table} WHERE institute_id=:i AND id=:id FOR UPDATE",
                {"i": institute_id, "id": identity_id},
            )
            if not row:
                raise APIError(404, "NOT_FOUND", "Person not found.")
            if row["auth_user_id"]:
                raise APIError(409, "LOGIN_EXISTS", "This person already has a login account.")
            auth_user_id = await create_login_account(auth, settings, row["official_email"], body.password)
            await conn.execute(_link_sql(), {"k": role, "id": str(identity_id), "a": auth_user_id})
            await conn.execute(_role_sql(), {"a": auth_user_id, "r": role})
            return {"id": str(identity_id), "auth_user_id": auth_user_id, "login_created": True}

        return await provision(request, user, institute_id, body, key, call)

    @app.post("/v1/admin/teachers/{identity_id}/login", status_code=201)
    async def create_teacher_login(
        identity_id: UUID, body: LoginCreate, request: Request, user: User, institute_id: Institute, key: Key
    ):
        return await add_login("teacher", identity_id, body, request, user, institute_id, key)

    @app.post("/v1/admin/students/{identity_id}/login", status_code=201)
    async def create_student_login(
        identity_id: UUID, body: LoginCreate, request: Request, user: User, institute_id: Institute, key: Key
    ):
        return await add_login("student", identity_id, body, request, user, institute_id, key)

    @app.post("/v1/admin/memberships", status_code=201)
    async def grant_role(body: RoleGrant, request: Request, user: User, institute_id: Institute, key: Key):
        async def call(conn):
            row = await one(
                conn,
                "SELECT app.admin_set_role(:a,:r,:s) AS id",
                {"a": str(body.auth_user_id), "r": body.role, "s": body.status},
            )
            return {"id": str(row["id"]), "role": body.role, "status": body.status}

        return await provision(request, user, institute_id, body, key, call)

    @app.post("/v1/admin/assignments", status_code=201)
    async def assign_teacher(body: Assignment, request: Request, user: User, institute_id: Institute, key: Key):
        async def call(conn):
            row = await one(
                conn,
                "SELECT app.admin_assign_teacher(:o,:t,:f) AS id",
                {"o": str(body.offering_id), "t": str(body.teacher_id), "f": body.can_finalize},
            )
            return {"id": str(row["id"])}

        return await provision(request, user, institute_id, body, key, call)


def _identity_call(body, kind, auth, settings):
    """Build the write that creates an identity row and, optionally, a login account."""
    number_column = {"teacher": "admin_create_teacher", "student": "admin_create_student"}[kind]

    async def call(conn):
        auth_user_id = None
        if body.create_login:
            auth_user_id = await create_login_account(
                auth, settings, body.official_email.lower(), body.password
            )
        row = await one(
            conn,
            f"SELECT app.{number_column}(:n,:name,:e) AS id",
            {"n": body.number, "name": body.official_name, "e": body.official_email},
        )
        identity_id = str(row["id"])
        if auth_user_id:
            await conn.execute(
                _link_sql(), {"k": kind, "id": identity_id, "a": auth_user_id}
            )
            await conn.execute(
                _role_sql(), {"a": auth_user_id, "r": kind}
            )
        return {"id": identity_id, "auth_user_id": auth_user_id, "login_created": bool(auth_user_id)}

    return call


def _link_sql():
    from sqlalchemy import text

    return text("SELECT app.admin_link_identity(:k,:id,:a)")


def _role_sql():
    from sqlalchemy import text

    return text("SELECT app.admin_set_role(:a,:r,'active')")
