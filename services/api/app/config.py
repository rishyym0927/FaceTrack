from pathlib import Path

from pydantic import SecretStr, field_validator, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=Path(__file__).parents[1] / ".env", extra="ignore")
    database_url: SecretStr
    supabase_url: str
    supabase_publishable_key: SecretStr = SecretStr("")
    # Service-role (admin) key. Optional: only the admin "create login account" path needs it.
    supabase_service_role_key: SecretStr = SecretStr("")
    join_code_keys: dict[str, SecretStr]
    join_code_key_id: str = "v1"
    cors_origins: list[str] = ["http://localhost:5300", "http://localhost:5301"]
    environment: str = "development"
    supabase_storage_secret: SecretStr = SecretStr("")
    documents_bucket: str = "facetrack-documents-dev"
    resend_api_key: SecretStr = SecretStr("")
    resend_from: str = ""
    faculty_report_url: str = "http://localhost:5300"
    enrollment_bucket: str = "facetrack-enrollment-dev"
    template_keys: dict[str, SecretStr] = {}
    template_key_id: str = "v1"

    @field_validator("supabase_url")
    @classmethod
    def secure_url(cls, value):
        from urllib.parse import urlparse

        parsed = urlparse(value)
        if (
            parsed.scheme != "https"
            or not parsed.hostname
            or parsed.username
            or parsed.query
            or parsed.fragment
        ):
            raise ValueError("Supabase URL must be an HTTPS origin")
        if parsed.path not in ("", "/"):
            raise ValueError("Supabase URL must be an origin")
        return value.rstrip("/")

    @field_validator("join_code_keys")
    @classmethod
    def valid_keys(cls, value):
        if not value or any(len(bytes.fromhex(k.get_secret_value())) != 32 for k in value.values()):
            raise ValueError("Join-code keys must be 32-byte hexadecimal secrets")
        return value

    @field_validator("cors_origins")
    @classmethod
    def exact_origins(cls, values):
        from urllib.parse import urlparse

        for value in values:
            parsed = urlparse(value)
            if (
                parsed.scheme not in {"https", "http"}
                or not parsed.hostname
                or parsed.path
                or parsed.query
                or parsed.fragment
                or parsed.username
                or "*" in value
            ):
                raise ValueError("CORS entries must be exact HTTP(S) origins without paths")
            if parsed.scheme == "http" and parsed.hostname not in {"localhost", "127.0.0.1"}:
                raise ValueError("Non-local origins require HTTPS")
        return values

    @model_validator(mode="after")
    def active_key_exists(self):
        if self.join_code_key_id not in self.join_code_keys:
            raise ValueError("Active join-code key must exist in keyring")
        if self.template_keys and (
            self.template_key_id not in self.template_keys
            or any(
                len(bytes.fromhex(k.get_secret_value())) != 32 for k in self.template_keys.values()
            )
        ):
            raise ValueError("Template keyring needs an active 32-byte key")
        return self
