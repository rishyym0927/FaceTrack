"""Provider metadata contract regressions, synthetic HTTP responses only."""

import httpx
import pytest
from pydantic import SecretStr

from app.config import Settings
from app.storage import Storage


@pytest.mark.parametrize(
    "payload",
    [
        {"size": 50, "content_type": "video/mp4", "metadata": None},
        {"metadata": {"size": 50, "mimetype": "video/mp4"}},
        {"metadata": {"contentLength": 50, "contentType": "video/mp4"}},
    ],
)
async def test_storage_info_normalizes_provider_mime_contract(payload):
    settings = Settings(
        database_url="postgresql+psycopg://fixture:fixture@localhost/fixture",
        supabase_storage_secret=SecretStr("synthetic-only"),
    )
    storage = Storage(
        settings, transport=httpx.MockTransport(lambda _: httpx.Response(200, json=payload))
    )
    try:
        assert await storage.info({"bucket": "fixture", "object_key": "opaque"}) == {
            "size": 50,
            "mime_type": "video/mp4",
        }
    finally:
        await storage.client.aclose()
