"""Configure the private document bucket and expand the existing scoped worker."""

import asyncio
import hashlib
import os
from pathlib import Path

from dotenv import dotenv_values, load_dotenv

from app.config import Settings
from app.errors import APIError
from app.storage import Storage
from tools.seed import connect

ROOT = Path(__file__).resolve().parents[1]


async def bucket(settings):
    storage = Storage(settings)
    payload = {
        "id": settings.documents_bucket,
        "name": settings.documents_bucket,
        "public": False,
        "file_size_limit": 25 * 1024 * 1024,
        "allowed_mime_types": ["text/csv", "application/pdf"],
    }
    try:
        try:
            await storage.call("GET", "/bucket/" + settings.documents_bucket)
        except APIError as error:
            if error.code != "MEDIA_NOT_AVAILABLE":
                raise
            await storage.call("POST", "/bucket", json=payload)
        else:
            await storage.call("PUT", "/bucket/" + settings.documents_bucket, json=payload)
    finally:
        await storage.client.aclose()


def main():
    load_dotenv(ROOT / ".env")
    token = dotenv_values(ROOT.parent / "worker/.env").get("WORKER_TOKEN", "")
    if not token.startswith("ftw_"):
        raise SystemExit("Existing scoped worker is missing; no credential was changed.")
    asyncio.run(bucket(Settings()))
    with connect(os.environ["MIGRATION_DATABASE_URL"]) as conn:
        result = conn.execute(
            """UPDATE app.worker_identities
               SET allowed_kinds='["enrollment","recognition","timetable","report","delivery"]',version=version+1
               WHERE token_hash=%s AND status='active' AND expires_at>now() RETURNING id""",
            (hashlib.sha256(token.encode()).hexdigest(),),
        ).fetchone()
        if not result:
            raise SystemExit("Existing worker is unavailable; no credential was changed.")
    print("Private document bucket and existing worker capabilities configured. Token preserved.")


if __name__ == "__main__":
    main()
