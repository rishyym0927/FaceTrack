import os
from pathlib import Path
from urllib.parse import urlparse

from dotenv import load_dotenv

SERVICE = Path(__file__).resolve().parents[2]
load_dotenv(SERVICE / ".env")
API = os.environ.get("API_BASE_URL", "http://127.0.0.1:8000").rstrip("/")
TOKEN = os.environ.get("WORKER_TOKEN", "")
REDIS = os.environ.get("REDIS_URL", "")
MANIFEST = Path(os.environ.get("MANIFEST_PATH", "/not-configured"))
PROFILE = Path(os.environ.get("PROFILE_PATH", "/not-configured"))
MEDIA_ORIGIN = os.environ.get("MEDIA_ORIGIN", "")
TEMP = Path(os.environ.get("TEMP_ROOT", str(SERVICE / ".local/tmp")))


def validate():
    parsed = urlparse(API)
    if parsed.scheme != "https" and not (
        parsed.scheme == "http" and parsed.hostname in ("127.0.0.1", "localhost")
    ):
        raise RuntimeError("Worker API must use HTTPS or local loopback.")
    if not TOKEN.startswith("ftw_") or not REDIS or not MANIFEST.is_file() or not PROFILE.is_file():
        raise RuntimeError("Configure the scoped local worker first.")
    if urlparse(REDIS).hostname not in ("127.0.0.1", "localhost"):
        raise RuntimeError("This milestone uses a private loopback Redis broker.")
