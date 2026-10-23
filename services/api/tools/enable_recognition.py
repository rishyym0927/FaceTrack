"""Enable the existing local worker's tested recognition capability, preserving its token."""

import hashlib
import os
from pathlib import Path

from dotenv import dotenv_values, load_dotenv

from tools.seed import connect


def main():
    load_dotenv(Path(__file__).parents[1] / ".env")
    worker = dotenv_values(Path(__file__).parents[2] / "worker/.env")
    token = worker.get("WORKER_TOKEN", "")
    if not token.startswith("ftw_"):
        raise SystemExit("Provision the scoped worker first.")
    with connect(os.environ["MIGRATION_DATABASE_URL"]) as conn:
        result = conn.execute(
            "UPDATE app.worker_identities SET allowed_kinds='[\"enrollment\",\"recognition\"]',version=version+1 WHERE token_hash=%s AND status='active' AND expires_at>now() RETURNING id",
            (hashlib.sha256(token.encode()).hexdigest(),),
        ).fetchone()
        if not result:
            raise SystemExit("Existing worker is unavailable; no credentials changed.")
    print(
        "Existing worker can process enrolment and recognition. Token/model scope/expiry preserved."
    )


if __name__ == "__main__":
    main()
