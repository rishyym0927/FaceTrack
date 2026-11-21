"""Auth-account facts the claim path needs beyond a confirmed email."""

from uuid import UUID

import httpx

from .errors import APIError


async def confirmed_account(auth, principal, institute: UUID) -> str:
    """The confirmed email of the signed-in account, if it may claim an identity in ``institute``.

    An account an administrator provisioned carries ``app_metadata.provisioned_institute`` (set
    server-side, never by the user). Such an account belongs to that institute only, so an admin
    of one institute cannot mint a login and use it to claim a student of another. Accounts
    without the marker (self sign-up) behave as before.
    """
    try:
        response = await auth.client.get(
            auth.settings.supabase_url + "/auth/v1/user",
            headers={
                "Authorization": "Bearer " + principal.token,
                "apikey": auth.settings.supabase_publishable_key.get_secret_value(),
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
        marker = (user.get("app_metadata") or {}).get("provisioned_institute")
        if marker and str(marker).lower() != str(institute).lower():
            raise APIError(
                404,
                "CLAIM_UNAVAILABLE",
                "Approved identity cannot be linked. Contact the institute.",
            )
        return user["email"].strip().lower()
    except (httpx.HTTPError, ValueError, KeyError) as exc:
        raise APIError(
            503, "AUTH_UNAVAILABLE", "Cannot confirm the current account email.", retryable=True
        ) from exc
