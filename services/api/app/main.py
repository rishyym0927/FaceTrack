import json
import logging
import time
from contextlib import asynccontextmanager
from typing import Annotated, Literal
from uuid import UUID, uuid4

import httpx
from fastapi import Depends, FastAPI, Header, Query, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy.exc import DBAPIError, IntegrityError
from starlette.exceptions import HTTPException

from . import schemas, services
from .auth import Authenticator
from .biometric_routes import install
from .config import Settings
from .db import make_engine, one, transaction
from .errors import APIError
from .security import expected_version
from .storage import Storage

logger = logging.getLogger("facetrack.api")
bearer = HTTPBearer(auto_error=False)
Institute = Annotated[UUID, Header(alias="X-Institute-ID")]
Key = Annotated[str, Header(alias="Idempotency-Key", min_length=1, max_length=128)]
Version = Annotated[str, Header(alias="If-Match")]
Limit = Annotated[int, Query(ge=1, le=200)]


def create_app(settings: Settings | None = None, *, auth_transport=None):
    settings = settings or Settings()
    engine = make_engine(settings.database_url.get_secret_value())
    client = httpx.AsyncClient(timeout=5, transport=auth_transport, follow_redirects=False)
    auth = Authenticator(settings, client)
    storage = Storage(settings)

    @asynccontextmanager
    async def lifespan(app):
        yield
        await storage.client.aclose()
        await client.aclose()
        await engine.dispose()

    app = FastAPI(
        title="FaceTrack API",
        version="0.1.0",
        lifespan=lifespan,
        debug=False,
        responses={
            code: {"model": schemas.ErrorEnvelope}
            for code in (401, 403, 404, 409, 413, 422, 429, 500, 503)
        },
    )
    app.state.engine, app.state.auth = engine, auth
    app.state.storage = storage
    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.cors_origins,
        allow_methods=["GET", "POST", "PUT", "PATCH", "DELETE"],
        allow_headers=[
            "Authorization",
            "Content-Type",
            "X-Institute-ID",
            "Idempotency-Key",
            "If-Match",
        ],
        expose_headers=["X-Request-ID"],
        allow_credentials=False,
    )

    def error_response(request, status, code, message, retryable=False, details=None):
        return JSONResponse(
            status_code=status,
            content={
                "error": {
                    "code": code,
                    "message": message,
                    "request_id": request.state.request_id,
                    "retryable": retryable,
                    "details": details or [],
                }
            },
        )

    @app.middleware("http")
    async def bounded_requests(request, call_next):
        request.state.request_id = str(uuid4())
        start = time.perf_counter()

        def finalize(response):
            response.headers["X-Request-ID"] = request.state.request_id
            response.headers["Cache-Control"] = "no-store"
            response.headers["X-Content-Type-Options"] = "nosniff"
            response.headers["X-Frame-Options"] = "DENY"
            response.headers["Referrer-Policy"] = "no-referrer"
            response.headers["Permissions-Policy"] = "camera=(), microphone=(), geolocation=()"
            return response

        def log(response):
            route = request.scope.get("route")
            logger.info(
                json.dumps(
                    {
                        "request_id": request.state.request_id,
                        "route": getattr(route, "path", "unmatched"),
                        "status": response.status_code,
                        "duration_ms": round((time.perf_counter() - start) * 1000, 3),
                    }
                )
            )
            return response

        maximum = 1024 * 1024
        data, total = [], 0
        async for chunk in request.stream():
            total += len(chunk)
            if total > maximum:
                response = error_response(
                    request, 413, "BODY_TOO_LARGE", "Request body exceeds 1 MiB."
                )
                return log(finalize(response))
            data.append(chunk)
        request._body = b"".join(data)
        return log(finalize(await call_next(request)))

    @app.exception_handler(HTTPException)
    async def http_error(request, error):
        return error_response(
            request, error.status_code, "HTTP_ERROR", "Resource or method unavailable."
        )

    @app.exception_handler(APIError)
    async def api_error(request, error):
        response = error_response(request, error.status, error.code, error.message, error.retryable)
        if error.status == 401:
            response.headers["WWW-Authenticate"] = "Bearer"
        return response

    @app.exception_handler(RequestValidationError)
    async def validation_error(request, error):
        return error_response(
            request,
            422,
            "VALIDATION_FAILED",
            "Request fields are invalid.",
            details=[{"loc": list(e["loc"]), "type": e["type"]} for e in error.errors()],
        )

    @app.exception_handler(IntegrityError)
    async def integrity_error(request, error):
        return error_response(
            request,
            409,
            "INTEGRITY_CONFLICT",
            "Record conflicts with an existing record or relationship.",
        )

    @app.exception_handler(DBAPIError)
    async def database_error(request, error):
        return error_response(
            request, 503, "DATABASE_UNAVAILABLE", "Database operation unavailable.", True
        )

    @app.exception_handler(Exception)
    async def unexpected_error(request, error):
        return error_response(request, 500, "INTERNAL_ERROR", "The request could not be completed.")

    async def principal(
        credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer)],
    ):
        if not credentials or credentials.scheme.lower() != "bearer":
            raise APIError(401, "AUTHENTICATION_REQUIRED", "A user access token is required.")
        return await auth.verify(credentials.credentials)

    User = Annotated[object, Depends(principal)]

    @app.get("/health/live")
    async def live():
        return {"status": "live"}

    @app.get("/health/ready")
    async def ready(request: Request):
        try:
            async with engine.connect() as conn:
                row = await one(
                    conn,
                    """SELECT NOT rolsuper AND NOT rolbypassrls AS restricted
                    FROM pg_roles WHERE rolname=current_user""",
                )
                owner = await one(
                    conn,
                    "SELECT pg_has_role(current_user, c.relowner, 'MEMBER') AS owns FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='app' AND c.relname='offerings'",
                )
                policies = await one(
                    conn,
                    "SELECT count(*) AS count FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='app' AND c.relkind='r' AND c.relrowsecurity AND c.relforcerowsecurity",
                )
                revision = await one(conn, "SELECT version_num FROM public.alembic_version")
            configured = bool(settings.supabase_publishable_key.get_secret_value())
            if (
                not row
                or not row["restricted"]
                or not owner
                or owner["owns"]
                or policies["count"] != 36
                or revision["version_num"] != "0006_timetable_reports"
                or not configured
            ):
                raise ValueError()
            return {"status": "ready"}
        except Exception:
            return error_response(
                request,
                503,
                "NOT_READY",
                "Database or authentication configuration is not ready.",
                True,
            )

    @app.get("/v1/me", response_model=schemas.Me)
    async def own_profile(user: User):
        async with transaction(engine, user.user_id) as conn:
            return await services.me(conn, user.user_id)

    @app.get("/v1/me/enrollments", response_model=schemas.Page[schemas.OwnEnrollment])
    async def my_enrollments(
        user: User, institute_id: Institute, cursor: UUID | None = None, limit: Limit = 50
    ):
        async with transaction(engine, user.user_id, institute_id) as conn:
            return await services.own_enrollments(conn, user.user_id, institute_id, cursor, limit)

    @app.post("/v1/identity/claim", status_code=201, response_model=schemas.ClaimResult)
    async def identity_claim(
        body: schemas.IdentityClaim, request: Request, user: User, institute_id: Institute, key: Key
    ):
        email = await auth.confirmed_email(user)
        async with transaction(engine, user.user_id, institute_id, email) as conn:
            return await services.claim(
                conn, user.user_id, institute_id, email, body, key, request.state.request_id
            )

    @app.get(
        "/v1/academics/{kind}",
        response_model=schemas.Page[schemas.Course | schemas.Term | schemas.ClassGroup],
    )
    async def academic_lookups(
        kind: Literal["courses", "terms", "class-groups"],
        user: User,
        institute_id: Institute,
        cursor: UUID | None = None,
        limit: Limit = 50,
    ):
        async with transaction(engine, user.user_id, institute_id) as conn:
            return await services.academics(conn, user.user_id, institute_id, kind, cursor, limit)

    @app.get("/v1/offerings", response_model=schemas.Page[schemas.Offering])
    async def offerings(
        user: User, institute_id: Institute, cursor: UUID | None = None, limit: Limit = 50
    ):
        async with transaction(engine, user.user_id, institute_id) as conn:
            return await services.offering_list(conn, user.user_id, institute_id, cursor, limit)

    @app.post("/v1/offerings", status_code=201, response_model=schemas.Offering)
    async def create_offering(
        body: schemas.OfferingCreate,
        request: Request,
        user: User,
        institute_id: Institute,
        key: Key,
    ):
        async with transaction(engine, user.user_id, institute_id) as conn:
            return await services.create_offering(
                conn, user.user_id, institute_id, body, key, request.state.request_id
            )

    @app.get("/v1/offerings/{offering_id}", response_model=schemas.Offering)
    async def offering_detail(offering_id: UUID, user: User, institute_id: Institute):
        async with transaction(engine, user.user_id, institute_id) as conn:
            return await services.offering_detail(conn, user.user_id, institute_id, offering_id)

    @app.get("/v1/offerings/{offering_id}/join-code", response_model=schemas.Code)
    async def get_code(offering_id: UUID, user: User, institute_id: Institute):
        async with transaction(engine, user.user_id, institute_id) as conn:
            return await services.current_code(
                conn, user.user_id, institute_id, offering_id, settings
            )

    @app.post("/v1/offerings/{offering_id}/join-code", status_code=201, response_model=schemas.Code)
    async def rotate_code(
        offering_id: UUID,
        request: Request,
        user: User,
        institute_id: Institute,
        key: Key,
        version: Version,
    ):
        async with transaction(engine, user.user_id, institute_id) as conn:
            return await services.rotate_code(
                conn,
                user.user_id,
                institute_id,
                offering_id,
                key,
                expected_version(version),
                settings,
                request.state.request_id,
            )

    @app.post("/v1/enrollment-requests", status_code=201, response_model=schemas.Enrollment)
    async def enrollment_request(
        body: schemas.JoinRequest, request: Request, user: User, institute_id: Institute, key: Key
    ):
        async with transaction(engine, user.user_id, institute_id) as conn:
            return await services.request_enrollment(
                conn, user.user_id, institute_id, body, key, request.state.request_id
            )

    @app.get("/v1/offerings/{offering_id}/roster", response_model=schemas.Page[schemas.RosterEntry])
    async def roster(
        offering_id: UUID,
        user: User,
        institute_id: Institute,
        cursor: UUID | None = None,
        limit: Limit = 50,
        status: Literal["requested", "active", "rejected", "withdrawn"] | None = None,
    ):
        async with transaction(engine, user.user_id, institute_id) as conn:
            return await services.roster(
                conn, user.user_id, institute_id, offering_id, cursor, limit, status
            )

    @app.patch(
        "/v1/offerings/{offering_id}/enrollments/{enrollment_id}", response_model=schemas.Enrollment
    )
    async def approve(
        offering_id: UUID,
        enrollment_id: UUID,
        body: schemas.Decision,
        request: Request,
        user: User,
        institute_id: Institute,
        key: Key,
        version: Version,
    ):
        async with transaction(engine, user.user_id, institute_id) as conn:
            return await services.approve(
                conn,
                user.user_id,
                institute_id,
                offering_id,
                enrollment_id,
                body,
                key,
                expected_version(version),
                request.state.request_id,
            )

    install(app, engine, settings, principal, storage)
    from .attendance import install as install_attendance

    install_attendance(app, engine, settings, principal, storage)
    from .documents import install as install_documents

    install_documents(app, engine, settings, principal, storage, auth)
    return app
