"""Provision the hosted non-owner role; never print its password or connection URL."""

import os
import secrets
from pathlib import Path

from dotenv import load_dotenv
from psycopg import sql

from tools.seed import connect

ROOT = Path(__file__).resolve().parents[3]


def main():
    load_dotenv(ROOT / "services/api/.env")
    target = ROOT / ".local/backend/hosted-runtime-password"
    with connect(os.environ["MIGRATION_DATABASE_URL"]) as conn:
        role = conn.execute(
            "SELECT rolsuper,rolbypassrls,rolcreaterole,rolcreatedb FROM pg_roles WHERE rolname='facetrack_api'"
        ).fetchone()
        if role:
            if any(role) or not target.exists():
                raise RuntimeError(
                    "Existing role cannot be safely provisioned. Inspect it; do not overwrite its credentials."
                )
        else:
            target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            # Exclusive creation avoids replacing a previously provisioned credential.
            if not target.exists():
                with target.open("x") as output:
                    target.chmod(0o600)
                    output.write(secrets.token_urlsafe(32))
            if len(target.read_text()) < 32:
                raise RuntimeError("Private role credential is invalid; inspect before retrying.")
            conn.execute(
                sql.SQL(
                    "CREATE ROLE facetrack_api LOGIN PASSWORD {} NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS"
                ).format(sql.Literal(target.read_text()))
            )
        if conn.execute(
            "SELECT 1 FROM pg_auth_members am JOIN pg_roles r ON r.oid=am.member WHERE r.rolname='facetrack_api'"
        ).fetchone():
            raise RuntimeError("Runtime role must not inherit or SET ROLE to other roles.")
        dbname = conn.execute("SELECT current_database()").fetchone()[0]
        conn.execute(
            sql.SQL("GRANT CONNECT ON DATABASE {} TO facetrack_api").format(sql.Identifier(dbname))
        )
    print(
        "Restricted role provisioned. Password is in .local/backend/hosted-runtime-password (private)."
    )


if __name__ == "__main__":
    main()
