"""Save an operator connection locally, prompting privately for its password."""

import argparse
import getpass
import re
from pathlib import Path

from dotenv import set_key
from sqlalchemy import make_url


def operator_url(connection, password):
    url = make_url(connection)
    if (
        url.drivername != "postgresql"
        or not url.host
        or not url.host.endswith(".pooler.supabase.com")
        or url.port != 5432
        or not re.fullmatch(r"postgres\.[a-z0-9]{20}", url.username or "")
        or url.database != "postgres"
        or not password
    ):
        raise ValueError("Use the session-pooler URI from the project's Connect panel.")
    return url.set(drivername="postgresql+psycopg", password=password, query={"sslmode": "require"})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("connection", help="Session URI with [YOUR-PASSWORD] placeholder only")
    args = parser.parse_args()
    # Credentials must be entered at the hidden prompt, never as process arguments/history.
    if make_url(args.connection).password != "[YOUR-PASSWORD]":
        parser.error(
            "Leave [YOUR-PASSWORD] in the URI; enter the real password at the hidden prompt."
        )
    target = Path(__file__).resolve().parents[1] / ".env"
    if not target.is_file() or target.is_symlink():
        parser.error(
            "Initialize the local backend environment first; expected its existing private .env."
        )
    password = getpass.getpass("Supabase database password (hidden): ")
    url = operator_url(args.connection, password)
    project = url.username.split(".", 1)[1]
    target.chmod(0o600)
    set_key(target, "MIGRATION_DATABASE_URL", url.render_as_string(hide_password=False))
    set_key(target, "SUPABASE_URL", f"https://{project}.supabase.co")
    target.chmod(0o600)
    print(
        "Operator connection saved privately. Runtime role, publishable key and hosted checks are still pending."
    )


if __name__ == "__main__":
    main()
