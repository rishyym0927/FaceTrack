import hashlib
import json
import os
import secrets
from datetime import datetime, timezone
from uuid import uuid4

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from sqlalchemy import text

from .db import many, one
from .errors import APIError


async def roles(conn, actor, institute):
    found = await many(
        conn,
        """SELECT m.role FROM app.memberships m JOIN app.institutes i ON i.id=m.institute_id
        WHERE m.institute_id=:i AND m.auth_user_id=:a AND m.status='active' AND i.status='active'""",
        {"i": institute, "a": actor},
    )
    if not found:
        raise APIError(403, "MEMBERSHIP_REQUIRED", "Active institute membership is required.")
    return {row["role"] for row in found}


async def teacher_access(conn, actor, institute, offering, *, lock=False):
    permissions = await roles(conn, actor, institute)
    row = await one(
        conn,
        "SELECT * FROM app.offerings WHERE institute_id=:i AND id=:o"
        + (" FOR UPDATE" if lock else ""),
        {"i": institute, "o": offering},
    )
    if not row:
        raise APIError(404, "NOT_FOUND", "Offering not found.")
    if "admin" not in permissions:
        assigned = await one(
            conn,
            """SELECT ot.id FROM app.offering_teachers ot
            JOIN app.teachers t ON t.institute_id=ot.institute_id AND t.id=ot.teacher_id
            WHERE ot.institute_id=:i AND ot.offering_id=:o AND ot.status='active'
            AND t.auth_user_id=:a AND t.status='approved'""",
            {"i": institute, "o": offering, "a": actor},
        )
        if "teacher" not in permissions or not assigned:
            raise APIError(404, "NOT_FOUND", "Offering not found.")
    return row


async def audit(conn, actor, institute, action, resource_type, resource, request_id):
    await conn.execute(
        text("""INSERT INTO app.audit_events
        (institute_id,actor_id,action,resource_type,resource_id,request_id)
        VALUES (:i,:a,:action,:type,:r,:req)"""),
        {
            "i": institute,
            "a": actor,
            "action": action,
            "type": resource_type,
            "r": resource,
            "req": request_id,
        },
    )


async def idempotent(conn, actor, institute, route, key, payload):
    if not key or len(key) > 128 or any(ord(c) < 33 or ord(c) > 126 for c in key):
        raise APIError(
            422,
            "IDEMPOTENCY_KEY_REQUIRED",
            "Supply an Idempotency-Key of 1–128 visible ASCII characters.",
        )
    fingerprint = hashlib.sha256(
        json.dumps(payload, sort_keys=True, separators=(",", ":"), default=str).encode()
    ).hexdigest()
    lock = f"{institute}:{actor}:{route}:{key}"
    await conn.execute(
        text("SELECT pg_advisory_xact_lock(hashtextextended(:value,0))"), {"value": lock}
    )
    found = await one(
        conn,
        """SELECT * FROM app.idempotency_records WHERE institute_id=:i
        AND actor_id=:a AND route=:r AND key=:k FOR UPDATE""",
        {"i": institute, "a": actor, "r": route, "k": key},
    )
    if found and found["expires_at"] > datetime.now(timezone.utc):
        if found["request_hash"] != fingerprint:
            raise APIError(409, "IDEMPOTENCY_CONFLICT", "Key was used with a different request.")
        return found["response_json"], fingerprint
    return None, fingerprint


async def remember(conn, actor, institute, route, key, fingerprint, result, status=201):
    await conn.execute(
        text("""INSERT INTO app.idempotency_records
        (institute_id,actor_id,route,key,request_hash,response_status,response_json,expires_at)
        VALUES (:i,:a,:r,:k,:h,:s,CAST(:body AS jsonb),now()+interval '24 hours')
        ON CONFLICT(institute_id,actor_id,route,key) DO UPDATE SET request_hash=excluded.request_hash,
        response_status=excluded.response_status,response_json=excluded.response_json,
        expires_at=excluded.expires_at,updated_at=now()"""),
        {
            "i": institute,
            "a": actor,
            "r": route,
            "k": key,
            "h": fingerprint,
            "s": status,
            "body": json.dumps(result, default=str),
        },
    )


async def code_quota(conn, actor, institute):
    # Failed lookups must not disappear on request rollback. Count all attempts, including successes.
    row = await one(
        conn,
        """INSERT INTO app.rate_limit_windows
        (institute_id,actor_id,action,window_start,attempts)
        VALUES (:i,:a,'join_code',to_timestamp(floor(extract(epoch from now())/600)*600),1)
        ON CONFLICT(institute_id,actor_id,action,window_start)
        DO UPDATE SET attempts=app.rate_limit_windows.attempts+1,updated_at=now()
        RETURNING attempts""",
        {"i": institute, "a": actor},
    )
    if row["attempts"] > 10:
        raise APIError(
            429,
            "JOIN_CODE_RATE_LIMIT",
            "Try again after the current ten-minute window.",
            retryable=True,
            commit=True,
        )


def code_hash(raw):
    normalized = raw.replace("-", "").replace(" ", "").upper()
    return hashlib.sha256(normalized.encode()).hexdigest()


def encrypted_code(settings, institute, offering):
    code_id = uuid4()
    raw = "".join(secrets.choice("ABCDEFGHJKLMNPQRSTUVWXYZ23456789") for _ in range(12))
    display = "-".join(raw[i : i + 4] for i in range(0, 12, 4))
    nonce = os.urandom(12)
    aad = f"{institute}:{offering}:{code_id}".encode()
    key_id = settings.join_code_key_id
    if key_id not in settings.join_code_keys:
        raise APIError(503, "CODE_KEY_UNAVAILABLE", "Join code encryption key unavailable.")
    key = bytes.fromhex(settings.join_code_keys[key_id].get_secret_value())
    return {
        "id": code_id,
        "code_hash": code_hash(raw),
        "ciphertext": AESGCM(key).encrypt(nonce, display.encode(), aad),
        "nonce": nonce,
        "key_id": key_id,
    }


def reveal_code(settings, row):
    try:
        key = bytes.fromhex(settings.join_code_keys[row["key_id"]].get_secret_value())
        aad = f"{row['institute_id']}:{row['offering_id']}:{row['id']}".encode()
        raw = AESGCM(key).decrypt(row["nonce"], row["ciphertext"], aad).decode()
        return {
            "id": row["id"],
            "offering_id": row["offering_id"],
            "code": raw,
            "expires_at": row["expires_at"],
            "version": row["version"],
        }
    except (ValueError, KeyError, InvalidTag, UnicodeDecodeError) as exc:
        raise APIError(503, "CODE_KEY_UNAVAILABLE", "Join code cannot be recovered.") from exc


async def check_cursor(conn, cursor, query, params):
    """Reject a cursor that names no row of this list; `query` selects it by `:cur`."""
    if cursor is not None and not await one(conn, query, {**params, "cur": cursor}):
        raise APIError(422, "INVALID_CURSOR", "The list cursor is not valid. Reload the list.")


def page(items, limit):
    rows = items[:limit]
    return {
        "items": [dict(row) for row in rows],
        "next_cursor": str(rows[-1]["id"]) if len(items) > limit else None,
    }


def expected_version(value: str | None) -> int:
    try:
        number = int((value or "").strip('"'))
        if number < 1:
            raise ValueError()
        return number
    except ValueError as exc:
        raise APIError(
            422, "VERSION_REQUIRED", "Supply If-Match with the current integer version."
        ) from exc
