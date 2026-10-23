"""Outbound-only local dispatcher. PostgreSQL leases recover lost Redis messages."""

import time

import httpx

from . import config
from .executor import api, app, clean_abandoned


def main():
    config.validate()
    clean_abandoned()
    maintenance = 0
    with httpx.Client(timeout=20, follow_redirects=False) as client:
        while True:
            try:
                if time.monotonic() - maintenance > 60:
                    result = api(client, "POST", "/internal/v1/maintenance/reconcile").json()
                    if result.get("overdue_media") or result.get("deletion_failures"):
                        print("Enrolment media cleanup backlog requires attention.", flush=True)
                    clean_abandoned()
                    maintenance = time.monotonic()
                response = api(client, "POST", "/internal/v1/jobs/claim")
                if response.status_code != 204:
                    lease = response.json()
                    app.send_task("facetrack.enroll", args=[lease["id"], lease["lease_epoch"]])
                time.sleep(2)
            except (httpx.HTTPError, ConnectionError):
                print("Enrolment agent waiting for local API/broker.", flush=True)
                time.sleep(5)
            except KeyboardInterrupt:
                return


if __name__ == "__main__":
    main()
