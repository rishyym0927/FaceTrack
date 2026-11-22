"""Anonymous diagnostics from the web and phone apps, written to the server log only.

Strictly whitelisted: a fixed list of event names and a handful of bounded numeric fields. No
free text, names, tokens or URLs can pass the schema, so apps cannot leak them even by mistake.
There is no storage and no migration; events are correlated with the server's own logs through
the attendance session id.

Each event is validated on its own. One event this server does not know (an app build newer or
older than the server) is counted and skipped; it must never cost the rest of the batch, which
may hold the upload events of a whole class.
"""

import logging
from datetime import UTC, datetime, timedelta
from typing import Annotated, Literal, get_args
from uuid import UUID

from fastapi import Depends, Request
from pydantic import Field, ValidationError, model_validator

from . import logs
from .errors import APIError
from .schemas import Strict

EventName = Literal[
    "scan_started",
    "scan_stopped",
    "scan_paused",
    "scan_resumed",
    "segment_recorded",
    "upload_retry",
    "upload_failed",
    "upload_done",
    "camera_failed",
    "camera_interrupted",
    "camera_recovered",
    "camera_switched",
    "recognition_load_failed",
    "api_error",
    "app_error",
]
EVENT_NAMES = get_args(EventName)
Code = Annotated[str, Field(pattern=r"^[A-Za-z0-9_.-]{1,60}$")]
MAX_EVENTS = 50
MAX_AGE_MS = 24 * 3600 * 1000


class ClientEvent(Strict):
    name: EventName
    session_id: UUID | None = None
    code: Code | None = None
    route: Annotated[str, Field(pattern=r"^/[A-Za-z0-9_/{}.-]{0,100}$")] | None = None
    status: int | None = Field(default=None, ge=100, le=599)
    attempt: int | None = Field(default=None, ge=0, le=1000)
    seconds: float | None = Field(default=None, ge=0, le=3600)
    bytes: int | None = Field(default=None, ge=0, le=1_000_000_000)
    duration_ms: int | None = Field(default=None, ge=0, le=3_600_000)
    count: int | None = Field(default=None, ge=0, le=100_000)
    # How long before the batch was sent the event happened. The server's own timestamp is the
    # time the batch arrived, which can be many seconds later; this restores the real moment.
    age_ms: int | None = Field(default=None, ge=0, le=MAX_AGE_MS)


class ClientBatch(Strict):
    app: Literal["teacher", "student"]
    platform: Literal["web", "android", "ios", "other"]
    version: Annotated[str, Field(pattern=r"^[0-9A-Za-z.+-]{1,32}$")] | None = None
    # Coarse, anonymous context for "why was this phone slow": no model name, no identifiers.
    device_class: Literal["phone", "tablet", "desktop", "unknown"] | None = None
    network: Literal["wifi", "cellular", "ethernet", "offline", "unknown"] | None = None
    net_class: Literal["slow-2g", "2g", "3g", "4g"] | None = None
    downlink_mbps: float | None = Field(default=None, ge=0, le=100_000)
    rtt_ms: int | None = Field(default=None, ge=0, le=600_000)
    events: list[ClientEvent] = Field(max_length=MAX_EVENTS)
    # Not part of the request: how many events in this batch were unusable.
    rejected: int = Field(default=0, ge=0, le=MAX_EVENTS, exclude=True)

    @model_validator(mode="before")
    @classmethod
    def keep_usable_events(cls, data):
        if not isinstance(data, dict):
            return data
        raw = data.get("events")
        if not isinstance(raw, list) or not 1 <= len(raw) <= MAX_EVENTS:
            raise ValueError("A batch carries between 1 and 50 events.")
        usable = []
        for item in raw:
            try:
                usable.append(ClientEvent.model_validate(item).model_dump(exclude_none=True))
            except ValidationError:
                pass
        return {**data, "events": usable, "rejected": len(raw) - len(usable)}


# A busy scan sends a few events a minute; this is generous and stops a runaway client.
budget = logs.Budget(limit=300, seconds=600)


def install(app, principal):
    @app.post("/v1/client-events", status_code=202)
    async def client_events(body: ClientBatch, request: Request, user=Depends(principal)):
        if not budget.take(str(user.user_id), len(body.events) + (1 if body.rejected else 0)):
            raise APIError(
                429, "RATE_LIMITED", "Too many diagnostic events.", retryable=True
            )
        received = datetime.now(UTC)
        context = {
            "request_id": request.state.request_id,
            "client": body.app,
            "platform": body.platform,
            "version": body.version,
            "device_class": body.device_class,
            "network": body.network,
            "net_class": body.net_class,
            "downlink_mbps": body.downlink_mbps,
            "rtt_ms": body.rtt_ms,
        }
        for item in body.events:
            fields = {
                # not "status": that field is how --errors recognises a server error
                ("http_status" if k == "status" else k): v
                for k, v in item.model_dump(exclude={"name", "age_ms"}).items()
                if v is not None
            }
            if item.age_ms is not None:
                fields["event_at"] = (received - timedelta(milliseconds=item.age_ms)).isoformat(
                    timespec="milliseconds"
                )
            logs.event("client_event", kind=item.name, **context, **fields)
        if body.rejected:
            logs.event(
                "client_events_rejected",
                level=logging.WARNING,
                count=body.rejected,
                **{k: v for k, v in context.items() if k in ("request_id", "client", "platform", "version")},
            )
        return {"accepted": len(body.events), "rejected": body.rejected}
