"""Outbound-only local dispatcher. PostgreSQL leases recover lost Redis messages."""

import os
import time

import httpx
from kombu.exceptions import OperationalError

from . import config, log
from .executor import api, app, clean_abandoned

CREDENTIAL_REJECTED = (
    "Worker credential rejected or expired. Processing is paused: ask the project owner to reissue it."
)
WAITING = "Enrolment agent waiting for local API/broker."
BROKER_WAITING = "Enrolment agent waiting for the Redis broker."
MAINTENANCE_FAILED = "Storage maintenance failed; job claiming continues."


def failure_notice(error):
    """Message and retry delay for a failed API call. A rejected credential
    must not look like a network problem: it never fixes itself."""
    if isinstance(error, httpx.HTTPStatusError) and error.response.status_code in (401, 403):
        return CREDENTIAL_REJECTED, 60
    return WAITING, 5


_noticed = {}


def notice(message, level="warning", **fields):
    """A recurring problem is logged once, then at most once a minute with a repeat count,
    so an outage does not flood the log."""
    now = time.monotonic()
    last, repeats, _ = _noticed.get(message, (None, 0, level))
    if last is not None and now - last < 60:
        _noticed[message] = (last, repeats + 1, level)
        return
    log.event("agent_notice", level, message=message, repeats=repeats or None, **fields)
    _noticed[message] = (now, 0, level)


def recovered():
    """Mark earlier problems as resolved so the next occurrence is logged at once. Only real
    problems (warnings and errors) are announced, not the routine 'worker busy' note."""
    problems = [v for v in _noticed.values() if v[2] != "info"]
    if problems:
        log.event(
            "agent_recovered", cleared=len(problems), suppressed=sum(v[1] for v in problems) or None
        )
    _noticed.clear()


def maintain(client):
    result = api(client, "POST", "/internal/v1/maintenance/reconcile").json()
    overdue, failures = result.get("overdue_media"), result.get("deletion_failures")
    if overdue or failures:
        notice(
            "Enrolment media cleanup backlog requires attention.",
            overdue_media=overdue,
            deletion_failures=failures,
        )
    clean_abandoned()


SLOTS = max(1, int(os.environ.get("WORKER_SLOTS", "1")))


# A job runs at most about 7 minutes (120 s download + 300 s inference + completion). Messages
# delivered longer ago than this belong to a worker that was killed mid-job; Celery only
# redelivers them after the 900 s visibility timeout.
STALE_UNACKED_SECONDS = 600


def backlog():
    """Jobs already handed to Celery and not finished: waiting in Redis or being run.

    A lease starts ticking when it is claimed, so claiming ahead of a busy worker lets queued
    leases expire (120 s) and burns their attempts. Claim only when a slot is free. On any
    error this returns 0, which keeps the previous claim-always behaviour.

    Unacknowledged messages older than ``STALE_UNACKED_SECONDS`` are not counted: after a worker
    container was killed (OOM, ``docker kill``, host reboot) its message stayed in ``unacked``
    for 15 minutes, and with WORKER_SLOTS of them the agent stopped claiming for that long.
    """
    try:
        with app.connection_for_read() as connection:
            client = connection.default_channel.client
            queued = int(client.llen("enrollment"))
            try:
                running = int(client.zcount("unacked_index", time.time() - STALE_UNACKED_SECONDS, "+inf"))
            except Exception:
                running = int(client.hlen("unacked"))
            return queued + running
    except Exception:
        return 0


# A claimed lease whose hand-off to the broker failed. Retried while the lease is
# still valid, so a short Redis outage does not burn one of the job's attempts.
PENDING = {}
HANDOFF_WINDOW = 90


def dispatch(lease):
    lease = {"id": lease["id"], "lease_epoch": lease["lease_epoch"]}  # validate before remembering
    retry = bool(PENDING)
    PENDING["lease"] = (lease, time.monotonic())
    app.send_task("facetrack.enroll", args=[lease["id"], lease["lease_epoch"]])
    PENDING.clear()
    log.event(
        "job_dispatched", job_id=lease["id"], lease_epoch=lease["lease_epoch"], after_retry=retry
    )


def cycle(client, maintenance):
    """One claim round. Returns (last maintenance time, seconds to sleep)."""
    try:
        if PENDING:
            lease, claimed_at = PENDING["lease"]
            if time.monotonic() - claimed_at > HANDOFF_WINDOW:
                log.event("handoff_abandoned", "error", job_id=lease["id"])
                PENDING.clear()  # the lease is about to expire; reconcile re-queues it
            else:
                dispatch(lease)
                return maintenance, 2
        if time.monotonic() - maintenance > 60:
            # Isolated: a failing reconcile must never stop job claiming. Retried next minute.
            maintenance = time.monotonic()
            log.event("resources", backlog=backlog(), **log.resources())
            try:
                maintain(client)
            except (httpx.HTTPError, ConnectionError, OSError, ValueError):
                notice(MAINTENANCE_FAILED)
        waiting = backlog()
        if waiting >= SLOTS:
            notice("Worker busy; not claiming more jobs.", "info", backlog=waiting)
            return maintenance, 1
        response = api(client, "POST", "/internal/v1/jobs/claim")
        recovered()
        if response.status_code != 204:
            dispatch(response.json())
            # Another slot is still free: claim again at once instead of after the idle pause.
            return maintenance, 0.2 if waiting + 1 < SLOTS else 2
        return maintenance, 2
    except OperationalError:
        # The claimed lease stays in PostgreSQL and is recovered after it expires.
        notice(BROKER_WAITING, "error", pending=bool(PENDING))
        return maintenance, 5
    except (ValueError, KeyError, TypeError):
        # A malformed claim is rejected before it is remembered, so a pending lease is kept.
        notice("Unexpected claim response from the API; will retry.", "error")
        return maintenance, 5
    except (httpx.HTTPError, ConnectionError) as error:
        message, delay = failure_notice(error)
        status = getattr(getattr(error, "response", None), "status_code", None)
        notice(message, "error", status=status, error=type(error).__name__)
        return maintenance, delay
    except Exception as error:
        # A bug or an unforeseen error must not kill the agent: it would restart in a loop and
        # drop every pending hand-off. Log it (class only) and carry on.
        notice("Unexpected agent error; will retry.", "error", error=type(error).__name__)
        return maintenance, 5


def main():
    config.validate()
    clean_abandoned()
    maintenance = 0
    with httpx.Client(timeout=20, follow_redirects=False) as client:
        try:
            while True:
                maintenance, delay = cycle(client, maintenance)
                time.sleep(delay)
        except KeyboardInterrupt:
            return


if __name__ == "__main__":
    main()
