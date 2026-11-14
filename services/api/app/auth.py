import asyncio
import time
from dataclasses import dataclass, field
from uuid import UUID

import httpx
import jwt

from .errors import APIError


@dataclass(frozen=True)
class Principal:
    user_id: UUID
    token: str = field(repr=False)


class Authenticator:
    def __init__(self, settings, client: httpx.AsyncClient):
        self.settings, self.client = settings, client
        self.keys, self.loaded_at = {}, None
        self.lock = asyncio.Lock()

    async def verify(self, token: str) -> Principal:
        try:
            if len(token) > 8192:
                raise ValueError()
            header = jwt.get_unverified_header(token)
            kid = header.get("kid")
            if header.get("alg") != "ES256" or not isinstance(kid, str) or not 1 <= len(kid) <= 200:
                raise ValueError()
            now = time.monotonic()
            if self.loaded_at is None or now - self.loaded_at > 300 or (
                kid not in self.keys and now - self.loaded_at > 30
            ):
                async with self.lock:
                    now = time.monotonic()
                    if self.loaded_at is None or now - self.loaded_at > 300 or (
                        kid not in self.keys and now - self.loaded_at > 30
                    ):
                        try:
                            response = await self.client.get(
                                self.settings.supabase_url + "/auth/v1/.well-known/jwks.json"
                            )
                            response.raise_for_status()
                            data = response.json()
                            if len(data["keys"]) > 20:
                                raise ValueError()
                            self.keys = {
                                key["kid"]: jwt.PyJWK.from_dict(key, algorithm="ES256").key
                                for key in data["keys"]
                                if key.get("kty") == "EC"
                                and key.get("crv") == "P-256"
                                and key.get("alg", "ES256") == "ES256"
                            }
                            self.loaded_at = now
                        except (httpx.HTTPError, ValueError, KeyError, jwt.PyJWTError) as exc:
                            raise APIError(
                                503,
                                "AUTH_UNAVAILABLE",
                                "Authentication provider unavailable.",
                                retryable=True,
                            ) from exc
            if kid not in self.keys:
                raise ValueError()
            claims = jwt.decode(
                token,
                self.keys[kid],
                algorithms=["ES256"],
                issuer=self.settings.supabase_url + "/auth/v1",
                audience="authenticated",
                leeway=30,
                options={"require": ["exp", "iat", "iss", "aud", "sub"]},
            )
            if claims.get("role") != "authenticated" or claims.get("is_anonymous") is True:
                raise ValueError()
            return Principal(UUID(claims["sub"]), token)
        except (jwt.PyJWTError, ValueError, KeyError, TypeError) as exc:
            raise APIError(401, "INVALID_TOKEN", "A valid user access token is required.") from exc

    async def confirmed_email(self, principal: Principal) -> str:
        try:
            response = await self.client.get(
                self.settings.supabase_url + "/auth/v1/user",
                headers={
                    "Authorization": "Bearer " + principal.token,
                    "apikey": self.settings.supabase_publishable_key.get_secret_value(),
                },
            )
            if response.status_code in (401, 403):
                raise APIError(401, "INVALID_TOKEN", "The current Auth session is invalid.")
            response.raise_for_status()
            user = response.json()
            if (
                UUID(user["id"]) != principal.user_id
                or not user.get("email_confirmed_at")
                or not user.get("email")
            ):
                raise APIError(
                    403, "EMAIL_UNCONFIRMED", "Confirm the approved email before claiming identity."
                )
            return user["email"].strip().lower()
        except (httpx.HTTPError, ValueError, KeyError) as exc:
            raise APIError(
                503, "AUTH_UNAVAILABLE", "Cannot confirm the current account email.", retryable=True
            ) from exc
