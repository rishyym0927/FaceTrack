"""Private synthetic transport probe only; never submits fake video to ML."""

import asyncio
from base64 import b64encode
from uuid import uuid4

import httpx

from app.config import Settings
from app.storage import Storage


async def main():
    settings = Settings()
    adapter = Storage(settings)
    asset = {
        "bucket": settings.enrollment_bucket,
        "object_key": "transport-probe/" + uuid4().hex,
        "mime_type": "video/webm",
        "reservation_expires_at": None,
    }
    content = b"facetrack synthetic transport probe, not a face video"
    try:
        grant = await adapter.upload(asset)
        headers = {
            "apikey": settings.supabase_publishable_key.get_secret_value(),
            "x-signature": grant["token"],
            "Tus-Resumable": "1.0.0",
        }
        metadata = ",".join(
            k + " " + b64encode(v.encode()).decode()
            for k, v in {
                "bucketName": asset["bucket"],
                "objectName": asset["object_key"],
                "contentType": asset["mime_type"],
            }.items()
        )
        async with httpx.AsyncClient(timeout=30, follow_redirects=False) as client:
            r = await client.post(
                grant["tus_url"],
                headers={
                    **headers,
                    "Upload-Length": str(len(content)),
                    "Upload-Metadata": metadata,
                },
                content=b"",
            )
            print("TUS create status:", r.status_code)
            if r.status_code >= 400:
                data = r.json()
                print({k: data[k] for k in ("statusCode", "error", "message") if k in data})
            r.raise_for_status()
            from urllib.parse import urljoin

            location = urljoin(grant["tus_url"], r.headers["location"])
            assert location.startswith(grant["tus_url"] + "/"), "Unexpected upload location"
            r = await client.patch(
                location,
                headers={
                    **headers,
                    "Upload-Offset": "0",
                    "Content-Type": "application/offset+octet-stream",
                },
                content=content,
            )
            print("TUS append status:", r.status_code)
            r.raise_for_status()
            assert int(r.headers["upload-offset"]) == len(content)
            info = await adapter.info(asset)
            assert info["size"] == len(content), info
            assert info["mime_type"] == asset["mime_type"], "Storage MIME contract mismatch"
            signed = await adapter.download(asset)
            read = await client.get(signed)
            assert read.content == content
            public = await client.get(
                settings.supabase_url
                + "/storage/v1/object/public/"
                + asset["bucket"]
                + "/"
                + asset["object_key"]
            )
            assert public.status_code != 200
            print(
                "Private upload/metadata/signed download/anonymous denial passed; synthetic object cleanup follows."
            )
    finally:
        await adapter.delete(asset)
        await adapter.client.aclose()


if __name__ == "__main__":
    asyncio.run(main())
