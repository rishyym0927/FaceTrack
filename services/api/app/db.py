from contextlib import asynccontextmanager
from contextvars import ContextVar
from time import monotonic, perf_counter
from uuid import UUID

from sqlalchemy import event, text
from sqlalchemy.exc import DisconnectionError
from sqlalchemy.ext.asyncio import create_async_engine

from .errors import APIError

pool_wait_ms: ContextVar[list[float] | None] = ContextVar("pool_wait_ms", default=None)


# A connection that sat unused this long may have been dropped by a firewall, NAT or pooler, so it
# is tested before reuse. A connection used moments ago is not: testing every checkout cost one
# network round trip (~125 ms to the hosted database) on every request.
IDLE_PING_SECONDS = 30.0


def make_engine(url: str):
    engine = create_async_engine(
        url,
        pool_size=12,
        max_overflow=0,
        pool_timeout=10,
        connect_args={"connect_timeout": 5},
    )
    dialect = engine.sync_engine.dialect

    @event.listens_for(engine.sync_engine, "checkin")
    def checked_in(dbapi_connection, record):
        record.info["checked_in_at"] = monotonic()

    @event.listens_for(engine.sync_engine, "checkout")
    def checked_out(dbapi_connection, record, proxy):
        since = record.info.pop("checked_in_at", None)
        if since is None or monotonic() - since < IDLE_PING_SECONDS:
            return
        try:
            alive = dialect.do_ping(dbapi_connection)
        except Exception as exc:
            raise DisconnectionError("Idle connection failed its liveness check.") from exc
        if not alive:
            raise DisconnectionError("Idle connection failed its liveness check.")

    return engine


async def context(
    conn, actor: UUID, institute: UUID | None = None, email: str = "", worker_hash: str = ""
):
    await conn.execute(
        text("""SELECT set_config('app.actor_id', :actor, true),
        set_config('app.worker_token_hash', :worker, true),
        set_config('app.institute_id', :institute, true),
        set_config('app.claim_email', :email, true),
        set_config('statement_timeout', '5000', true)"""),
        {
            "actor": str(actor) if actor else "",
            "institute": str(institute) if institute else "",
            "email": email.strip().lower(),
            "worker": worker_hash,
        },
    )


@asynccontextmanager
async def transaction(
    engine, actor: UUID | None, institute: UUID | None = None, email: str = "", worker_hash: str = ""
):
    started = perf_counter()
    async with engine.connect() as conn:
        if (samples := pool_wait_ms.get()) is not None:
            samples.append((perf_counter() - started) * 1000)
        tx = await conn.begin()
        try:
            # A pooled connection keeps its database role, so the check runs once per connection
            # instead of costing a round trip (~130 ms to the hosted database) on every request.
            info = conn.sync_connection.info
            if not info.get("role_restricted"):
                permission = await one(
                    conn,
                    """SELECT NOT r.rolsuper AND NOT r.rolbypassrls
                    AND NOT r.rolcreaterole AND NOT r.rolcreatedb
                    AND NOT pg_has_role(current_user,c.relowner,'MEMBER') AS restricted
                    FROM pg_roles r CROSS JOIN pg_class c
                    JOIN pg_namespace n ON n.oid=c.relnamespace
                    WHERE r.rolname=current_user AND n.nspname='app' AND c.relname='offerings'""",
                )
                if not permission or not permission["restricted"]:
                    raise APIError(
                        503,
                        "UNSAFE_DATABASE_ROLE",
                        "Restricted database configuration is required.",
                    )
                info["role_restricted"] = True
            await context(conn, actor, institute, email, worker_hash)
            yield conn
            await tx.commit()
        except APIError as exc:
            # Only an invalid-code quota write may commit on an error. Domain work otherwise rolls back.
            if exc.commit:
                await tx.commit()
            else:
                await tx.rollback()
            raise
        except BaseException:
            await tx.rollback()
            raise


async def one(conn, sql: str, params: dict | None = None):
    return (await conn.execute(text(sql), params or {})).mappings().first()


async def many(conn, sql: str, params: dict | None = None):
    return list((await conn.execute(text(sql), params or {})).mappings())
