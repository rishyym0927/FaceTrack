"""Attendance lifecycle with actual isolated PostgreSQL; synthetic Auth/media/ML."""

from datetime import datetime, timedelta, timezone

from test_biometrics import bio as bio

from tools.seed import connect


async def create(b):
    now = datetime.now(timezone.utc)
    body = {
        "offering_id": b.ids["offering"],
        "starts_at": (now - timedelta(minutes=1)).isoformat(),
        "ends_at": (now + timedelta(hours=1)).isoformat(),
    }
    r = await b.client.post("/v1/sessions", headers=b.headers("teacher", key="session"), json=body)
    assert r.status_code == 201, r.text
    again = await b.client.post(
        "/v1/sessions", headers=b.headers("teacher", key="session"), json=body
    )
    assert again.json() == r.json()
    return r.json()


async def open_session(b):
    s = await create(b)
    r = await b.client.post(
        f"/v1/sessions/{s['id']}/open", headers=b.headers("teacher", key="open", version=1)
    )
    assert r.status_code == 200, r.text
    return r.json()


async def test_session_roster_manual_publication_correction_history(bio):
    b = bio
    s = await open_session(b)
    sid = s["id"]
    for label in ("student1", "unassigned", "other_teacher"):
        denied = await b.client.get(f"/v1/sessions/{sid}/attendance", headers=b.headers(label))
        assert denied.status_code in (403, 404), denied.text
    rows = (
        await b.client.get(f"/v1/sessions/{sid}/attendance", headers=b.headers("teacher"))
    ).json()["items"]
    assert len(rows) == 1 and rows[0]["status"] == "unassessed"
    # Later membership changes cannot rewrite the frozen roster.
    with connect(b.urls["owner"]) as c:
        c.execute(
            "UPDATE app.course_enrollments SET status='withdrawn' WHERE offering_id=%s",
            (b.ids["offering"],),
        )
    close = await b.client.post(
        f"/v1/sessions/{sid}/close", headers=b.headers("teacher", key="close", version=s["version"])
    )
    assert close.status_code == 200, close.text
    s = close.json()
    assert s["status"] == "no_data"
    noack = await b.client.post(
        f"/v1/sessions/{sid}/finalize",
        headers=b.headers("teacher", key="noack", version=s["version"]),
        json={"decisions": []},
    )
    assert noack.status_code == 409
    decisions = {
        "decisions": [
            {
                "student_id": b.ids["student1_profile"],
                "status": "present",
                "reason": "Observed in class",
            }
        ]
    }
    p = await b.client.post(
        f"/v1/sessions/{sid}/finalize",
        headers=b.headers("teacher", key="publish", version=s["version"]),
        json=decisions,
    )
    assert p.status_code == 200, p.text
    duplicate = await b.client.post(
        f"/v1/sessions/{sid}/finalize",
        headers=b.headers("teacher", key="publish", version=s["version"]),
        json=decisions,
    )
    assert duplicate.json() == p.json()
    own = await b.client.get("/v1/me/attendance", headers=b.headers("student1"))
    assert own.status_code == 200, own.text
    assert own.json()["summary"]["percentage"] == 100 and len(own.json()["items"]) == 1
    other = await b.client.get("/v1/me/attendance", headers=b.headers("student2"))
    assert other.json()["items"] == [] and other.json()["summary"]["percentage"] is None
    current = (await b.client.get(f"/v1/sessions/{sid}", headers=b.headers("teacher"))).json()
    correction = await b.client.post(
        f"/v1/sessions/{sid}/corrections",
        headers=b.headers("teacher", key="correction", version=current["version"]),
        json={
            "student_id": b.ids["student1_profile"],
            "status": "excused",
            "reason": "Approved leave",
            "publication_revision": 1,
        },
    )
    assert correction.status_code == 200, correction.text
    own = (await b.client.get("/v1/me/attendance", headers=b.headers("student1"))).json()
    assert own["items"][0]["revision"] == 2 and own["summary"]["percentage"] is None
    with connect(b.urls["owner"]) as c:
        snapshots = c.execute(
            "SELECT snapshot_json FROM app.publications ORDER BY revision"
        ).fetchall()
        assert len(snapshots) == 2 and snapshots[0][0]["records"][0]["status"] == "present"


async def test_manual_capture_requires_two_active_templates(bio):
    b = bio
    s = await open_session(b)
    r = await b.client.post(
        f"/v1/sessions/{s['id']}/captures",
        headers=b.headers("teacher", key="capture"),
        json={
            "source_type": "webcam",
            "recorded_at": datetime.now(timezone.utc).isoformat(),
            "mime_type": "video/webm",
            "expected_bytes": 256,
        },
    )
    assert r.status_code == 409 and r.json()["error"]["code"] == "INSUFFICIENT_TEMPLATES"
    # No fake media/job is generated for an ineligible roster.
    with connect(b.urls["owner"]) as c:
        assert c.execute("SELECT count(*) FROM app.captures").fetchone()[0] == 0


async def recognition_ready(b):
    from test_biometrics import process

    with connect(b.urls["owner"]) as c:
        c.execute(
            "INSERT INTO app.course_enrollments(institute_id,offering_id,student_id,status) VALUES(%s,%s,%s,'active')",
            (b.ids["institute"], b.ids["offering"], b.ids["student2_profile"]),
        )
        c.execute('UPDATE app.worker_identities SET allowed_kinds=\'["enrollment","recognition"]\'')
    for label in ("student1", "student2"):
        original = b.headers
        b.headers = lambda who="teacher", **kw: original(label if who == "student1" else who, **kw)
        try:
            a, _, _, _ = await process(b, key=label)
        finally:
            b.headers = original
        current = (
            await b.client.get(f"/v1/biometric-enrollments/{a['id']}", headers=b.headers(label))
        ).json()
        r = await b.client.post(
            f"/v1/biometric-enrollments/{a['id']}/approve",
            headers=b.headers("teacher", key=label + "approve", version=current["version"]),
            json={"identity_confirmed": True, "poses_confirmed": True},
        )
        assert r.status_code == 200, r.text
    return await open_session(b)


async def captured(b, s):
    r = await b.client.post(
        f"/v1/sessions/{s['id']}/captures",
        headers=b.headers("teacher", key="capture"),
        json={
            "source_type": "webcam",
            "recorded_at": datetime.now(timezone.utc).isoformat(),
            "mime_type": "video/webm",
            "expected_bytes": 256,
        },
    )
    assert r.status_code == 201, r.text
    cap = r.json()
    r = await b.client.post(f"/v1/captures/{cap['id']}/upload-grant", headers=b.headers("teacher"))
    assert r.status_code == 200, r.text
    body = {"asset_id": cap["asset_id"], "byte_size": 256, "sha256": "c" * 64}
    r = await b.client.post(
        f"/v1/captures/{cap['id']}/upload-complete",
        headers=b.headers("teacher", key="completecapture"),
        json=body,
    )
    assert r.status_code == 202, r.text
    claim = await b.client.post("/internal/v1/jobs/claim", headers=b.wh)
    assert claim.status_code == 200, claim.text
    job = claim.json()
    jid = job["id"]
    epoch = job["lease_epoch"]
    assert (
        await b.client.post(f"/internal/v1/jobs/{jid}/start", headers=b.wh, json={"epoch": epoch})
    ).status_code == 200
    data = await b.client.get(
        f"/internal/v1/jobs/{jid}/input", headers=b.wh, params={"epoch": epoch}
    )
    assert data.status_code == 200, data.text
    return cap, jid, epoch, data.json()


async def test_recognition_roster_encryption_proposals_manual_lock_and_replay(bio):
    b = bio
    s = await recognition_ready(b)
    cap, jid, epoch, data = await captured(b, s)
    assert len(data["roster"]) == 2 and len(data["roster"][0]["vectors"][0]) == 512
    # A manual decision cannot be overwritten by later ML proposals.
    review = await b.client.put(
        f"/v1/sessions/{s['id']}/attendance-review",
        headers=b.headers("teacher", key="review", version=s["version"]),
        json={
            "decisions": [
                {
                    "student_id": b.ids["student1_profile"],
                    "status": "excused",
                    "reason": "Approved leave",
                }
            ]
        },
    )
    assert review.status_code == 200, review.text
    proposals = [
        {
            "student_id": p["student_id"],
            "template_set_id": p["template_set_id"],
            "template_epoch": p["template_epoch"],
            "hits": 2,
            "span_ms": 600,
            "similarity": 0.9,
        }
        for p in data["roster"]
    ]
    body = {
        k: data[k]
        for k in ("generation", "source_sha256", "model_hash", "profile_hash", "roster_hash")
    }
    body.update(
        epoch=epoch,
        processed_sha256="d" * 64,
        proposals=proposals,
        unknown_observations=1,
        quality={"detections": 5},
        timings={"processing_total_ms": 2},
    )
    r = await b.client.post(f"/internal/v1/jobs/{jid}/complete", headers=b.wh, json=body)
    assert r.status_code == 200, r.text
    assert (
        await b.client.post(f"/internal/v1/jobs/{jid}/complete", headers=b.wh, json=body)
    ).json() == r.json()
    rows = (
        await b.client.get(f"/v1/sessions/{s['id']}/attendance", headers=b.headers("teacher"))
    ).json()["items"]
    byid = {p["student_id"]: p for p in rows}
    assert byid[b.ids["student1_profile"]]["status"] == "excused"
    assert byid[b.ids["student2_profile"]]["status"] == "proposed_present"
    for label in ("student1", "unassigned", "other_teacher"):
        assert (
            await b.client.get(f"/v1/captures/{cap['id']}", headers=b.headers(label))
        ).status_code in (403, 404)
    with connect(b.urls["owner"]) as c:
        assert c.execute("SELECT count(*) FROM app.recognition_evidence").fetchone()[0] == 2


async def test_withdrawal_blocks_inflight_recognition_commit(bio):
    b = bio
    s = await recognition_ready(b)
    _, jid, epoch, data = await captured(b, s)
    state = (
        await b.client.get("/v1/me/biometric-enrollment", headers=b.headers("student2"))
    ).json()
    assert (
        await b.client.delete(
            "/v1/consents/" + state["consent"]["id"], headers=b.headers("student2")
        )
    ).status_code == 200
    body = {
        k: data[k]
        for k in ("generation", "source_sha256", "model_hash", "profile_hash", "roster_hash")
    }
    body.update(
        epoch=epoch,
        processed_sha256="d" * 64,
        proposals=[],
        unknown_observations=0,
        quality={},
        timings={},
    )
    r = await b.client.post(f"/internal/v1/jobs/{jid}/complete", headers=b.wh, json=body)
    assert r.status_code == 409, r.text
    with connect(b.urls["owner"]) as c:
        assert c.execute("SELECT count(*) FROM app.recognition_evidence").fetchone()[0] == 0
