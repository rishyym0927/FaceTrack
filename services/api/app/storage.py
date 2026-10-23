"""Server-only private Storage adapter. Signed capabilities never enter logs/replay records."""

from urllib.parse import quote, urlparse

import httpx

from .errors import APIError


class Storage:
    def __init__(self, settings, *, transport=None):
        self.settings = settings
        self.base = settings.supabase_url + "/storage/v1"
        self.client = httpx.AsyncClient(timeout=30, transport=transport, follow_redirects=False)

    async def call(self, method, path, **kwargs):
        key = self.settings.supabase_storage_secret.get_secret_value()
        if not key:
            raise APIError(
                503, "STORAGE_NOT_CONFIGURED", "Private Storage is not configured.", retryable=True
            )
        try:
            response = await self.client.request(
                method,
                self.base + path,
                headers={"apikey": key, **kwargs.pop("headers", {})},
                **kwargs,
            )
            missing = response.status_code == 404
            if response.status_code == 400:
                try:
                    missing = str(response.json().get("statusCode")) == "404"
                except ValueError:
                    pass
            if missing:
                raise APIError(409, "MEDIA_NOT_AVAILABLE", "The reserved video is not available.")
            response.raise_for_status()
            return response
        except httpx.HTTPError:
            raise APIError(
                503,
                "STORAGE_UNAVAILABLE",
                "Private Storage is unavailable. Please retry.",
                retryable=True,
            ) from None

    def path(self, asset):
        return quote(asset["bucket"], safe="") + "/" + quote(asset["object_key"], safe="/")

    async def upload(self, asset):
        data = (
            await self.call(
                "POST", "/object/upload/sign/" + self.path(asset), json={"upsert": False}
            )
        ).json()
        token = data.get("token")
        if not token:
            from urllib.parse import parse_qs

            token = parse_qs(urlparse(data.get("url", "")).query).get("token", [None])[0]
        if not token:
            raise APIError(
                503, "STORAGE_UNAVAILABLE", "Upload authorization is unavailable.", retryable=True
            )
        return {
            "token": token,
            "bucket": asset["bucket"],
            "object_key": asset["object_key"],
            "tus_url": self.base.replace(".supabase.co/storage", ".storage.supabase.co/storage")
            + "/upload/resumable/sign",
            "mime_type": asset["mime_type"],
            "reservation_expires_at": asset["reservation_expires_at"],
        }

    async def info(self, asset):
        data = (await self.call("GET", "/object/info/" + self.path(asset))).json()
        metadata = data.get("metadata") or data
        return {
            "size": int(metadata.get("size", metadata.get("contentLength", data.get("size", -1)))),
            "mime_type": metadata.get(
                "mimetype", metadata.get("contentType", data.get("content_type", ""))
            ),
        }

    async def download(self, asset, seconds=60):
        data = (
            await self.call("POST", "/object/sign/" + self.path(asset), json={"expiresIn": seconds})
        ).json()
        path = data.get("signedURL") or data.get("signedUrl")
        if not isinstance(path, str):
            raise APIError(
                503, "STORAGE_UNAVAILABLE", "Video access is unavailable.", retryable=True
            )
        url = path if path.startswith("https://") else self.base + path
        if urlparse(url).hostname != urlparse(self.settings.supabase_url).hostname:
            raise APIError(
                503, "STORAGE_UNAVAILABLE", "Video access is unavailable.", retryable=True
            )
        return url

    async def delete(self, asset):
        try:
            await self.call(
                "DELETE",
                "/object/" + quote(asset["bucket"], safe=""),
                json={"prefixes": [asset["object_key"]]},
            )
        except APIError as e:
            if e.code != "MEDIA_NOT_AVAILABLE":
                raise

    async def put(self, asset, content):
        await self.call(
            "POST",
            "/object/" + self.path(asset),
            content=content,
            headers={"Content-Type": asset["mime_type"], "x-upsert": "false"},
        )
