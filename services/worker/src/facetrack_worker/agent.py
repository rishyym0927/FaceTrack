"""Outbound-only local dispatcher. PostgreSQL leases recover lost Redis messages."""

import os
import time

import httpx
from kombu.exceptions import OperationalError

from . import config
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


def maintain(client):
    result = api(client, "POST", "/internal/v1/maintenance/reconcile").json()
    if result.get("overdue_media") or result.get("deletion_failures"):
        print("Enrolment media cleanup backlog requires attention.", flush=True)
    clean_abandoned()


SLOTS = max(1, int(os.environ.get("WORKER_SLOTS", "1")))


def backlog():
    """Jobs already handed to Celery and not finished: waiting in Redis or being run.

    A lease starts ticking when it is claimed, so claiming ahead of a busy worker lets queued
    leases expire (120 s) and burns their attempts. Claim only when a slot is free. On any
    error this returns 0, which keeps the previous claim-always behaviour.
    """
    try:
        with app.connection_for_read() as connection:
            client = connection.default_channel.client
            return int(client.llen("enrollment")) + int(client.hlen("unacked"))
    except Exception:
        return 0


# A claimed lease whose hand-off to the broker failed. Retried while the lease is
# still valid, so a short Redis outage does not burn one of the job's attempts.
PENDING = {}
HANDOFF_WINDOW = 90


def dispatch(lease):
    lease = {"id": lease["id"], "lease_epoch": lease["lease_epoch"]}  # validate before remembering
    PENDING["lease"] = (lease, time.monotonic())
    app.send_task("facetrack.enroll", args=[lease["id"], lease["lease_epoch"]])
    PENDING.clear()


def cycle(client, maintenance):
    """One claim round. Returns (last maintenance time, seconds to sleep)."""
    try:
        if PENDING:
            lease, claimed_at = PENDING["lease"]
            if time.monotonic() - claimed_at > HANDOFF_WINDOW:
                PENDING.clear()  # the lease is about to expire; reconcile re-queues it
            else:
                dispatch(lease)
                return maintenance, 2
        if time.monotonic() - maintenance > 60:
            # Isolated: a failing reconcile must never stop job claiming. Retried next minute.
            maintenance = time.monotonic()
            try:
                maintain(client)
            except (httpx.HTTPError, ConnectionError, OSError, ValueError):
                print(MAINTENANCE_FAILED, flush=True)
        if backlog() >= SLOTS:
            return maintenance, 1
        response = api(client, "POST", "/internal/v1/jobs/claim")
        if response.status_code != 204:
            dispatch(response.json())
        return maintenance, 2
    except OperationalError:
        # The claimed lease stays in PostgreSQL and is recovered after it expires.
        print(BROKER_WAITING, flush=True)
        return maintenance, 5
    except (ValueError, KeyError, TypeError):
        print("Unexpected claim response from the API; will retry.", flush=True)
        return maintenance, 5
    except (httpx.HTTPError, ConnectionError) as error:
        message, delay = failure_notice(error)
        print(message, flush=True)
        return maintenance, delay


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
