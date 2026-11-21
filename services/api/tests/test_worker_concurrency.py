import asyncio

from test_attendance import queued_capture, recognition_ready
from test_biometrics import bio as bio  # noqa: F401

from tools.seed import connect


async def test_one_identity_holds_up_to_the_lease_limit_without_double_claims(bio, monkeypatch):
    b = bio
    monkeypatch.setenv("WORKER_MAX_LEASES", "2")
    s = await recognition_ready(b)
    for n in range(3):
        await queued_capture(b, s, key=f"cap{n}")
    first, second = await asyncio.gather(
        b.client.post("/internal/v1/jobs/claim", headers=b.wh),
        b.client.post("/internal/v1/jobs/claim", headers=b.wh),
    )
    assert first.status_code == 200 and second.status_code == 200
    assert first.json()["id"] != second.json()["id"]
    third = await b.client.post("/internal/v1/jobs/claim", headers=b.wh)
    assert third.status_code == 204  # the identity is at its limit; one job is still queued
    with connect(b.urls["owner"]) as c:
        states = sorted(r[0] for r in c.execute("SELECT state FROM app.jobs WHERE kind='recognition'").fetchall())
    assert states == ["leased", "leased", "queued"]


async def test_lease_limit_defaults_to_two_and_can_be_one(bio, monkeypatch):
    b = bio
    s = await recognition_ready(b)
    for n in range(2):
        await queued_capture(b, s, key=f"cap{n}")
    monkeypatch.setenv("WORKER_MAX_LEASES", "1")
    assert (await b.client.post("/internal/v1/jobs/claim", headers=b.wh)).status_code == 200
    assert (await b.client.post("/internal/v1/jobs/claim", headers=b.wh)).status_code == 204
    monkeypatch.delenv("WORKER_MAX_LEASES")
    assert (await b.client.post("/internal/v1/jobs/claim", headers=b.wh)).status_code == 200


async def test_fractional_span_is_stored_exactly(bio):
    from test_attendance import captured

    b = bio
    s = await recognition_ready(b)
    cap, jid, epoch, data = await captured(b, s)
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
                "span_ms": 1234.5,
                "similarity": 0.9,
            }
            for p in data["roster"]
        ],
        unknown_observations=0,
        quality={"detections": 5},
        timings={"processing_total_ms": 2},
    )
    r = await b.client.post(f"/internal/v1/jobs/{jid}/complete", headers=b.wh, json=body)
    assert r.status_code == 200, r.text
    with connect(b.urls["owner"]) as c:
        spans = {x[0] for x in c.execute("SELECT span_ms FROM app.recognition_evidence").fetchall()}
    assert spans == {1234.5}
