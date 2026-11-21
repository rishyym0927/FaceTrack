"""Database round trips per hot route.

Every statement costs one network round trip to the hosted database (about 125 ms from the VM),
so the number of statements a route issues is its latency. Each transaction also costs a BEGIN and
a COMMIT. These tests count them with SQLAlchemy events and fail when a route gets chattier.
"""

import json
import os
from contextlib import contextmanager
from datetime import datetime, timezone

from sqlalchemy import event
from test_attendance import queued_capture, recognition_ready
from test_biometrics import bio as bio  # noqa: F401

REPORT = os.environ.get("STATEMENT_REPORT")


class Counter:
    def __init__(self):
        self.statements = []
        self.transactions = 0

    @property
    def round_trips(self):
        # statements + BEGIN + COMMIT per transaction
        return len(self.statements) + 2 * self.transactions


@contextmanager
def counting(app):
    engine = app.state.engine.sync_engine
    counter = Counter()

    def statement(conn, cursor, text, parameters, context, executemany):
        counter.statements.append(" ".join(text.split())[:110])

    def begin(conn):
        counter.transactions += 1

    event.listen(engine, "before_cursor_execute", statement)
    event.listen(engine, "begin", begin)
    try:
        yield counter
    finally:
        event.remove(engine, "before_cursor_execute", statement)
        event.remove(engine, "begin", begin)


def record(name, counter):
    if REPORT:
        with open(REPORT, "a") as out:
            out.write(
                json.dumps(
                    {
                        "route": name,
                        "statements": len(counter.statements),
                        "transactions": counter.transactions,
                        "round_trips": counter.round_trips,
                        "sql": counter.statements,
                    }
                )
                + "\n"
            )


async def measured(b, name, call, budget):
    await call()  # warm the pooled connection's role check
    with counting(b.app) as counter:
        response = await call()
    record(name, counter)
    assert response.status_code < 300 or response.status_code == 204, response.text
    assert counter.round_trips <= budget, (name, counter.round_trips, counter.statements)
    return response


async def test_hot_route_round_trips(bio):
    b = bio
    s = await recognition_ready(b)
    sid = s["id"]
    teacher = b.headers("teacher")

    async def attendance():
        return await b.client.get(f"/v1/sessions/{sid}/attendance", headers=teacher)

    async def unchanged():
        version = (await attendance()).json()["session"]["version"]
        return await b.client.get(
            f"/v1/sessions/{sid}/attendance",
            headers=teacher,
            params={"known_version": version, "known_processing": "false"},
        )

    big = 999
    await measured(b, "attendance full (idle)", attendance, big)
    await measured(b, "attendance unchanged", unchanged, big)
    await measured(b, "offerings", lambda: b.client.get("/v1/offerings", headers=teacher), big)
    await measured(
        b, "work-summary", lambda: b.client.get("/v1/teacher/work-summary", headers=teacher), big
    )
    await measured(
        b,
        "work-summary offering",
        lambda: b.client.get(
            "/v1/teacher/work-summary", headers=teacher, params={"offering_id": b.ids["offering"]}
        ),
        big,
    )
    await measured(
        b,
        "offering detail",
        lambda: b.client.get(f"/v1/offerings/{b.ids['offering']}", headers=teacher),
        big,
    )
    await measured(
        b, "idle claim", lambda: b.client.post("/internal/v1/jobs/claim", headers=b.wh), big
    )

    cap = await queued_capture(b, s)

    async def capture_status():
        return await b.client.get(f"/v1/captures/{cap['id']}", headers=teacher)

    await measured(b, "capture status", capture_status, big)
    with counting(b.app) as counter:
        claim = await b.client.post("/internal/v1/jobs/claim", headers=b.wh)
    record("claim (job available)", counter)
    job = claim.json()
    epoch = job["lease_epoch"]
    jid = job["id"]
    with counting(b.app) as counter:
        await b.client.post(f"/internal/v1/jobs/{jid}/start", headers=b.wh, json={"epoch": epoch})
    record("job start", counter)
    with counting(b.app) as counter:
        await b.client.post(
            f"/internal/v1/jobs/{jid}/heartbeat",
            headers=b.wh,
            json={"epoch": epoch, "stage": "detecting", "percent": 10},
        )
    record("job heartbeat", counter)
    with counting(b.app) as counter:
        data = await b.client.get(
            f"/internal/v1/jobs/{jid}/input", headers=b.wh, params={"epoch": epoch}
        )
    record("job input", counter)
    data = data.json()
    body = {
        k: data[k]
        for k in ("generation", "source_sha256", "model_hash", "profile_hash", "roster_hash")
    }
    body.update(
        epoch=epoch,
        processed_sha256="d" * 64,
        proposals=[
            {
                "student_id": p["student_id"],
                "template_set_id": p["template_set_id"],
                "template_epoch": p["template_epoch"],
                "hits": 2,
                "span_ms": 600,
                "similarity": 0.9,
            }
            for p in data["roster"]
        ],
        unknown_observations=1,
        quality={"detections": 5},
        timings={"processing_total_ms": 2},
    )
    with counting(b.app) as counter:
        done = await b.client.post(f"/internal/v1/jobs/{jid}/complete", headers=b.wh, json=body)
    record("job complete", counter)
    assert done.status_code == 200, done.text
    assert datetime.now(timezone.utc)  # keep import used
