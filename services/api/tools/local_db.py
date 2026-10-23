"""Manage only this checkout's isolated PostgreSQL development/test cluster."""

import argparse
import json
import os
import secrets
import shlex
import subprocess
import sys
from pathlib import Path

import psycopg
from psycopg import sql
from sqlalchemy import URL

ROOT = Path(__file__).resolve().parents[3]
LOCAL = ROOT / ".local/backend"
DATA = LOCAL / "postgres"
SOCKET = LOCAL / "socket"
PORT = 55432


def private_write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.write_text(value)
    path.chmod(0o600)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["start", "stop"])
    args = parser.parse_args()
    LOCAL.mkdir(parents=True, exist_ok=True, mode=0o700)
    LOCAL.chmod(0o700)
    SOCKET.mkdir(exist_ok=True, mode=0o700)
    marker = LOCAL / "managed.json"
    if DATA.exists() and not marker.exists():
        raise RuntimeError("Refusing to operate an unrecognized cluster.")
    if marker.exists() and json.loads(marker.read_text()).get("root") != str(ROOT):
        raise RuntimeError("Cluster belongs to another checkout.")
    if args.action == "stop":
        subprocess.run(["pg_ctl", "-D", str(DATA), "-m", "fast", "-w", "stop"], check=True)
        return
    if not DATA.exists():
        private_write(LOCAL / "owner.pw", secrets.token_urlsafe(32))
        subprocess.run(
            [
                "initdb",
                "-D",
                str(DATA),
                "-U",
                "facetrack_owner",
                "--pwfile",
                str(LOCAL / "owner.pw"),
                "--auth-local=trust",
                "--auth-host=scram-sha-256",
                "--encoding=UTF8",
                "--no-locale",
            ],
            check=True,
            capture_output=True,
        )
        private_write(marker, json.dumps({"managed_by": "facetrack", "root": str(ROOT)}))
    if json.loads(marker.read_text()).get("root") != str(ROOT):
        raise RuntimeError("Cluster belongs to another checkout.")
    if subprocess.run(["pg_ctl", "-D", str(DATA), "status"], capture_output=True).returncode:
        subprocess.run(
            [
                "pg_ctl",
                "-D",
                str(DATA),
                "-l",
                str(LOCAL / "postgres.log"),
                "-o",
                f"-h 127.0.0.1 -p {PORT} -k {shlex.quote(str(SOCKET))}",
                "-w",
                "start",
            ],
            check=True,
            capture_output=True,
        )
    secrets_file = LOCAL / "runtime-password"
    if not secrets_file.exists():
        private_write(secrets_file, secrets.token_urlsafe(32))
    password = secrets_file.read_text()
    with psycopg.connect(
        dbname="postgres", host=str(SOCKET), port=PORT, user="facetrack_owner", autocommit=True
    ) as conn:
        if not conn.execute("SELECT 1 FROM pg_roles WHERE rolname='facetrack_api'").fetchone():
            conn.execute(
                sql.SQL(
                    "CREATE ROLE facetrack_api LOGIN PASSWORD {} NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS"
                ).format(sql.Literal(password))
            )
        for name in ("facetrack_dev", "facetrack_test"):
            if not conn.execute("SELECT 1 FROM pg_database WHERE datname=%s", (name,)).fetchone():
                conn.execute(
                    sql.SQL("CREATE DATABASE {} OWNER facetrack_owner").format(sql.Identifier(name))
                )
    config = {}
    for label, name in [("development", "facetrack_dev"), ("test", "facetrack_test")]:
        owner = URL.create(
            "postgresql+psycopg",
            username="facetrack_owner",
            database=name,
            query={"host": str(SOCKET), "port": str(PORT)},
        ).render_as_string(hide_password=False)
        runtime = URL.create(
            "postgresql+psycopg",
            username="facetrack_api",
            password=password,
            host="127.0.0.1",
            port=PORT,
            database=name,
        ).render_as_string(hide_password=False)
        config[label] = {"owner": owner, "runtime": runtime}
        with psycopg.connect(
            dbname=name, host=str(SOCKET), port=PORT, user="facetrack_owner", autocommit=True
        ) as conn:
            conn.execute("REVOKE CREATE ON SCHEMA public FROM PUBLIC")
            conn.execute("CREATE SCHEMA IF NOT EXISTS auth")
            # Relational fixture only. This does NOT emulate Supabase Auth or mint login tokens.
            conn.execute(
                "CREATE TABLE IF NOT EXISTS auth.users(id uuid PRIMARY KEY,email text,email_confirmed_at timestamptz)"
            )
        env = {**os.environ, "MIGRATION_DATABASE_URL": owner}
        subprocess.run(
            [
                sys.executable,
                "-m",
                "alembic",
                "-c",
                str(ROOT / "services/api/alembic.ini"),
                "upgrade",
                "head",
            ],
            env=env,
            check=True,
        )
    private_write(LOCAL / "connections.json", json.dumps(config, indent=2))
    envfile = ROOT / "services/api/.env"
    if not envfile.exists():
        private_write(
            envfile,
            "\n".join(
                [
                    "DATABASE_URL=" + config["development"]["runtime"],
                    "MIGRATION_DATABASE_URL=" + config["development"]["owner"],
                    "SUPABASE_URL=https://not-configured.supabase.co",
                    "SUPABASE_PUBLISHABLE_KEY=",
                    "JOIN_CODE_KEYS=" + json.dumps({"v1": secrets.token_hex(32)}),
                    "JOIN_CODE_KEY_ID=v1",
                    'CORS_ORIGINS=["http://localhost:5300"]',
                    "ENVIRONMENT=development",
                    "",
                ]
            ),
        )
    print("Private PostgreSQL ready on loopback:55432. API environment created only if absent.")


if __name__ == "__main__":
    main()
