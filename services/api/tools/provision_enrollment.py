"""Provision approved local academic model metadata, private bucket and one scoped worker."""

import argparse
import asyncio
import hashlib
import json
import os
import secrets
import sys
from pathlib import Path
from uuid import UUID

from dotenv import load_dotenv

from app.config import Settings
from app.storage import Storage
from tools.seed import connect

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "services/worker/src"))
from facetrack_ml.config import canonical_hash, load_manifest, load_profile  # noqa: E402


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--institute", type=UUID)
    args = parser.parse_args()
    load_dotenv(ROOT / "services/api/.env")
    settings = Settings()
    institute = args.institute or UUID(
        json.loads((ROOT / ".local/backend/demo-ids.json").read_text())["institute"]
    )
    manifest_path = ROOT / ".local/spike/models/buffalo_sc/manifest.json"
    profile_path = ROOT / ".local/spike/profiles/frozen-phase1b-v1.json"
    manifest = load_manifest(manifest_path)
    model_hash = canonical_hash(manifest.model_dump())
    profile = load_profile(profile_path, model_hash)
    profile_hash = canonical_hash(profile.model_dump())
    storage = Storage(settings)
    try:
        payload = {
            "id": settings.enrollment_bucket,
            "name": settings.enrollment_bucket,
            "public": False,
            "file_size_limit": 25 * 1024 * 1024,
            "allowed_mime_types": ["video/mp4", "video/webm"],
        }
        # Existing bucket is updated only to the agreed private development limits.
        try:
            await storage.call("GET", "/bucket/" + settings.enrollment_bucket)
        except Exception as e:
            from app.errors import APIError

            if not isinstance(e, APIError) or e.code != "MEDIA_NOT_AVAILABLE":
                raise
            await storage.call("POST", "/bucket", json=payload)
        else:
            await storage.call("PUT", "/bucket/" + settings.enrollment_bucket, json=payload)
        print("Private enrolment bucket configured (25 MiB; MP4/WebM).")
    finally:
        await storage.client.aclose()
    directory = ROOT / ".local/enrollment"
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    worker_env = ROOT / "services/worker/.env"
    if worker_env.exists():
        raise SystemExit(
            "Worker environment already exists. Model/bucket verified; refusing to replace its token. Use the existing worker or explicitly revoke/reprovision."
        )
    token = "ftw_" + secrets.token_urlsafe(40)
    redis_password = secrets.token_urlsafe(32)
    with connect(os.environ["MIGRATION_DATABASE_URL"]) as conn:
        model = conn.execute(
            "INSERT INTO app.model_releases(institute_id,manifest_json,manifest_hash,license_status) VALUES(%s,%s,%s,'academic_local_only') ON CONFLICT(institute_id,manifest_hash) DO UPDATE SET manifest_hash=excluded.manifest_hash RETURNING id",
            (institute, json.dumps(manifest.model_dump()), model_hash),
        ).fetchone()[0]
        conn.execute(
            "INSERT INTO app.recognition_profiles(institute_id,model_release_id,settings_json,settings_hash) VALUES(%s,%s,%s,%s) ON CONFLICT(institute_id,model_release_id,settings_hash) DO NOTHING",
            (institute, model, json.dumps(profile.model_dump()), profile_hash),
        )
        conn.execute(
            "INSERT INTO app.worker_identities(institute_id,token_hash,allowed_model_hashes,expires_at) VALUES(%s,%s,%s,now()+interval '30 days')",
            (institute, hashlib.sha256(token.encode()).hexdigest(), json.dumps([model_hash])),
        )
    content = (
        "\n".join(
            [
                "API_BASE_URL=http://127.0.0.1:8000",
                "WORKER_TOKEN=" + token,
                "REDIS_URL=redis://:" + redis_password + "@127.0.0.1:6381/0",
                "MANIFEST_PATH=" + str(manifest_path),
                "PROFILE_PATH=" + str(profile_path),
                "MEDIA_ORIGIN=" + settings.supabase_url,
                "TEMP_ROOT=" + str(directory / "tmp"),
            ]
        )
        + "\n"
    )
    with worker_env.open("x") as stream:
        os.chmod(worker_env, 0o600)
        stream.write(content)
    config = directory / "redis.conf"
    config.write_text(
        "bind 127.0.0.1\nprotected-mode yes\nport 6381\nrequirepass "
        + redis_password
        + '\nsave ""\nappendonly no\n'
    )
    config.chmod(0o600)
    print(
        "Verified model/profile registered; scoped worker credential and private Redis config saved. No token/key printed."
    )


if __name__ == "__main__":
    asyncio.run(main())
