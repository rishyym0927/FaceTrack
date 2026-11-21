"""Read-only check that every institute with queued recognition work has a worker serving it.

A worker only receives jobs for the institute its credential belongs to. A credential for the
wrong institute looks perfectly healthy (it polls, gets "nothing to do", and logs no error) while
every segment waits forever. This is how that is caught:

    .venv/bin/python -m tools.check_worker

Exit status 1 when something needs attention. It never changes anything.
"""

import os
import re
import sys
from pathlib import Path

import psycopg

SILENCE_SECONDS = 90
STUCK_SECONDS = 90
EXPIRY_WARNING_DAYS = 7

QUERY = """
SELECT i.id::text AS institute_id, i.name,
  count(j.*) FILTER (WHERE j.state IN ('queued','retry_wait')) AS queued,
  coalesce(max(extract(epoch FROM (now()-j.created_at))) FILTER
    (WHERE j.state IN ('queued','retry_wait')), 0)::int AS oldest_queued_seconds,
  (SELECT count(*) FROM app.worker_identities w WHERE w.institute_id=i.id AND w.status='active'
     AND w.expires_at>now() AND w.allowed_kinds ? 'recognition') AS recognition_workers,
  (SELECT extract(epoch FROM (now()-max(w.last_seen_at)))::int FROM app.worker_identities w
     WHERE w.institute_id=i.id AND w.status='active' AND w.expires_at>now()
       AND w.allowed_kinds ? 'recognition') AS seconds_since_seen,
  (SELECT min(w.expires_at) FROM app.worker_identities w WHERE w.institute_id=i.id
     AND w.status='active' AND w.expires_at>now() AND w.allowed_kinds ? 'recognition') AS expires_at
FROM app.institutes i
LEFT JOIN app.jobs j ON j.institute_id=i.id AND j.kind='recognition'
GROUP BY i.id, i.name
ORDER BY queued DESC, i.name
"""


def findings(conn) -> list[dict]:
    """One entry per institute that needs attention, most serious first."""
    out = []
    for row in conn.execute(QUERY).fetchall():
        institute_id, name, queued, oldest, workers, since, expires = row
        problems = []
        if queued and workers == 0:
            problems.append("jobs are queued but no recognition worker credential exists")
        elif queued and (since is None or since > SILENCE_SECONDS) and oldest >= STUCK_SECONDS:
            problems.append(
                "jobs are queued but no worker for this institute has called in "
                f"for {'ever' if since is None else f'{since} s'}; check the worker's credential "
                "belongs to this institute"
            )
        if workers and expires is not None:
            days = (expires - conn.execute("SELECT now()").fetchone()[0]).days
            if days <= EXPIRY_WARNING_DAYS:
                problems.append(f"the worker credential expires in {days} days")
        if problems:
            out.append(
                {
                    "institute": institute_id[:8],
                    "name": name,
                    "queued": queued,
                    "oldest_queued_seconds": oldest,
                    "problems": problems,
                }
            )
    return out


def owner_url() -> str:
    url = os.environ.get("MIGRATION_DATABASE_URL")
    if not url:
        for line in Path(".env").read_text().splitlines():
            if line.startswith("MIGRATION_DATABASE_URL="):
                url = line.split("=", 1)[1].strip().strip("\"'")
    if not url:
        raise SystemExit("MIGRATION_DATABASE_URL is not set.")
    return re.sub(r"^postgresql\+\w+://", "postgresql://", url)


def main() -> int:
    with psycopg.connect(owner_url(), options="-c default_transaction_read_only=on") as conn:
        found = findings(conn)
    if not found:
        print("OK: every institute with queued recognition work has a worker serving it.")
        return 0
    for item in found:
        print(f"{item['institute']} {item['name']}: {item['queued']} queued "
              f"(oldest {item['oldest_queued_seconds']} s)")
        for problem in item["problems"]:
            print(f"  - {problem}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
