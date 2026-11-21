"""Anonymous diagnostics from the web and phone apps, written to the server log only.

Strictly whitelisted: a fixed list of event names and a handful of bounded numeric fields. No
free text, names, tokens or URLs can pass the schema, so apps cannot leak them even by mistake.
There is no storage and no migration; events are correlated with the server's own logs through
the attendance session id.
"""

from typing import Annotated, Literal
from uuid import UUID

from fastapi import Depends, Request
from pydantic import Field

from . import logs
from .errors import APIError
from .schemas import Strict

EventName = Literal[
    "scan_started",
    "scan_stopped",
    "segment_recorded",
    "upload_retry",
    "upload_failed",
    "upload_done",
    "camera_failed",
    "camera_interrupted",
    "camera_switched",
    "api_error",
    "app_error",
]
Code = Annotated[str, Field(pattern=r"^[A-Za-z0-9_.-]{1,60}$")]


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


class ClientBatch(Strict):
    app: Literal["teacher", "student"]
    platform: Literal["web", "android", "ios", "other"]
    version: Annotated[str, Field(pattern=r"^[0-9A-Za-z.+-]{1,32}$")] | None = None
    events: list[ClientEvent] = Field(min_length=1, max_length=50)


# A busy scan sends a few events a minute; this is generous and stops a runaway client.
budget = logs.Budget(limit=300, seconds=600)


def install(app, principal):
    @app.post("/v1/client-events", status_code=202)
    async def client_events(body: ClientBatch, request: Request, user=Depends(principal)):
        if not budget.take(str(user.user_id), len(body.events)):
            raise APIError(
                429, "RATE_LIMITED", "Too many diagnostic events.", retryable=True
            )
        for item in body.events:
            logs.event(
                "client_event",
                request_id=request.state.request_id,
                client=body.app,
                platform=body.platform,
                version=body.version,
                kind=item.name,
                **{
                    # not "status": that field is how --errors recognises a server error
                    ("http_status" if k == "status" else k): v
                    for k, v in item.model_dump(exclude={"name"}).items()
                    if v is not None
                },
            )
        return {"accepted": len(body.events)}
