from contextlib import asynccontextmanager
from uuid import UUID

from sqlalchemy import text
from sqlalchemy.ext.asyncio import create_async_engine

from .errors import APIError


def make_engine(url: str):
    return create_async_engine(
        url, pool_size=5, max_overflow=0, pool_pre_ping=True, connect_args={"connect_timeout": 5}
    )


async def context(conn, actor: UUID, institute: UUID | None = None, email: str = ""):
    await conn.execute(
        text("""SELECT set_config('app.actor_id', :actor, true),
        set_config('app.worker_token_hash', '', true),
        set_config('app.institute_id', :institute, true),
        set_config('app.claim_email', :email, true),
        set_config('statement_timeout', '5000', true)"""),
        {
            "actor": str(actor) if actor else "",
            "institute": str(institute) if institute else "",
            "email": email.strip().lower(),
        },
    )


@asynccontextmanager
async def transaction(engine, actor: UUID, institute: UUID | None = None, email: str = ""):
    async with engine.connect() as conn:
        tx = await conn.begin()
        try:
            permission = await one(
                conn,
                """SELECT NOT rolsuper AND NOT rolbypassrls
                AND NOT rolcreaterole AND NOT rolcreatedb AS restricted FROM pg_roles
                WHERE rolname=current_user""",
            )
            owner = await one(
                conn,
                """SELECT pg_has_role(current_user,c.relowner,'MEMBER') AS owns
                FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
                WHERE n.nspname='app' AND c.relname='offerings'""",
            )
            if not permission or not permission["restricted"] or not owner or owner["owns"]:
                raise APIError(
                    503, "UNSAFE_DATABASE_ROLE", "Restricted database configuration is required."
                )
            await context(conn, actor, institute, email)
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
