"""Durable document flows with real isolated PostgreSQL and synthetic external services."""

import base64
from datetime import date, timedelta

from test_attendance import open_session
from test_biometrics import bio as bio

from tools.seed import connect


async def allow_documents(b):
    with connect(b.urls["owner"]) as c:
        c.execute(
            'UPDATE app.worker_identities SET allowed_kinds=\'["enrollment","recognition","report","timetable","delivery"]\''
        )


async def test_report_job_snapshot_private_artifacts_and_retry(bio):
    b = bio
    await allow_documents(b)
    s = await open_session(b)
    close = await b.client.post(
        f"/v1/sessions/{s['id']}/close",
        headers=b.headers("teacher", key="close", version=s["version"]),
    )
    assert close.status_code == 200, close.text
    reports = (
        await b.client.get(f"/v1/sessions/{s['id']}/reports", headers=b.headers("teacher"))
    ).json()["items"]
    assert len(reports) == 1 and reports[0]["kind"] == "draft"
    claim = await b.client.post("/internal/v1/jobs/claim", headers=b.wh)
    assert claim.status_code == 200, claim.text
    jid = claim.json()["id"]
    epoch = claim.json()["lease_epoch"]
    assert (
        await b.client.post(f"/internal/v1/jobs/{jid}/start", headers=b.wh, json={"epoch": epoch})
    ).status_code == 200
    data = await b.client.get(
        f"/internal/v1/jobs/{jid}/input", headers=b.wh, params={"epoch": epoch}
    )
    assert data.status_code == 200, data.text
    assert (
        data.json()["kind"] == "report"
        and data.json()["snapshot"]["records"][0]["status"] == "unassessed"
    )
    assert data.json()["snapshot"]["course_code"] == "CS401"
    assert data.json()["snapshot"]["section"] == "A"
    stored = []

    async def put(a, blob):
        stored.append((a["mime_type"], blob))

    b.app.state.storage.put = put
    body = {
        "kind": "report",
        "epoch": epoch,
        "csv_base64": base64.b64encode(b"Synthetic CSV fixture").decode(),
        "pdf_base64": base64.b64encode(b"%PDF-1.4\nSynthetic fixture\n%%EOF").decode(),
    }
    r = await b.client.post(f"/internal/v1/jobs/{jid}/complete", headers=b.wh, json=body)
    assert r.status_code == 200, r.text
    assert len(stored) == 2
    assert (
        await b.client.post(f"/internal/v1/jobs/{jid}/complete", headers=b.wh, json=body)
    ).json() == r.json()
    assert len(stored) == 2
    rid = reports[0]["id"]
    with connect(b.urls["owner"]) as c:
        states = c.execute(
            """SELECT status,count(*) FROM app.media_assets
            WHERE purpose='report' AND institute_id=%s GROUP BY status""",
            (b.ids["institute"],),
        ).fetchall()
    assert sorted(states) == [("deleted", 2), ("uploaded", 2)]
    for label in ("student1", "unassigned", "other_teacher"):
        assert (
            await b.client.get(f"/v1/reports/{rid}/download", headers=b.headers(label))
        ).status_code in (403, 404)
    assert (
        await b.client.get(f"/v1/reports/{rid}/download", headers=b.headers("teacher"))
    ).status_code == 200
    email = await b.client.post(
        f"/v1/reports/{rid}/deliveries", headers=b.headers("teacher", key="email")
    )
    assert email.status_code == 503 and email.json()["error"]["code"] == "EMAIL_NOT_CONFIGURED"


async def test_failed_report_retry_requires_authorized_teacher_and_preserves_snapshot(bio):
    b = bio
    await allow_documents(b)
    s = await open_session(b)
    close = await b.client.post(
        f"/v1/sessions/{s['id']}/close",
        headers=b.headers("teacher", key="close-report-retry", version=s["version"]),
    )
    assert close.status_code == 200, close.text
    report = (
        await b.client.get(f"/v1/sessions/{s['id']}/reports", headers=b.headers("teacher"))
    ).json()["items"][0]
    with connect(b.urls["owner"]) as c:
        before = c.execute("SELECT snapshot_hash FROM app.reports WHERE id=%s", (report["id"],)).fetchone()[0]
        c.execute("UPDATE app.reports SET status='failed' WHERE id=%s", (report["id"],))
        c.execute("UPDATE app.jobs SET state='failed' WHERE report_id=%s", (report["id"],))
    path = f"/v1/reports/{report['id']}/retry"
    assert (await b.client.post(path, headers=b.headers("student1", key="retry-bad"))).status_code in (403, 404)
    r = await b.client.post(path, headers=b.headers("teacher", key="retry-good"))
    assert r.status_code == 202, r.text
    assert r.json()["state"] == "queued"
    assert (await b.client.post(path, headers=b.headers("teacher", key="retry-good"))).json() == r.json()
    with connect(b.urls["owner"]) as c:
        after = c.execute("SELECT snapshot_hash,status FROM app.reports WHERE id=%s", (report["id"],)).fetchone()
    assert after == (before, "queued")


async def test_timetable_import_rechecks_reservation_owner_after_storage_lookup(bio):
    b = bio
    reservation = await b.client.post(
        "/v1/media-reservations",
        headers=b.headers("teacher", key="reserve"),
        json={"purpose": "timetable", "mime_type": "text/csv", "expected_bytes": 256},
    )
    assert reservation.status_code == 201, reservation.text
    aid = reservation.json()["id"]
    info = b.app.state.storage.info

    async def changed_owner(asset):
        with connect(b.urls["owner"]) as c:
            c.execute(
                "UPDATE app.media_assets SET owner_user_id=%s WHERE id=%s",
                (b.users["other_teacher"]["id"], aid),
            )
        return await info(asset)

    b.app.state.storage.info = changed_owner
    r = await b.client.post(
        "/v1/timetable-imports",
        headers=b.headers("teacher", key="import"),
        json={
            "asset_id": aid,
            "term_id": b.ids["term"],
            "base_revision": 0,
            "byte_size": 256,
            "sha256": "c" * 64,
        },
    )
    assert r.status_code == 404, r.text
    with connect(b.urls["owner"]) as c:
        assert c.execute("SELECT status FROM app.media_assets WHERE id=%s", (aid,)).fetchone() == (
            "reserved",
        )


async def import_ready(b, key="import", revision=0, rows=None):
    await allow_documents(b)
    with connect(b.urls["owner"]) as c:
        c.execute(
            "INSERT INTO app.rooms(institute_id,code,name) VALUES(%s,'R1','Demo room') ON CONFLICT(institute_id,code) DO NOTHING",
            (b.ids["institute"],),
        )
    a = await b.client.post(
        "/v1/media-reservations",
        headers=b.headers("teacher", key=key + "asset"),
        json={"purpose": "timetable", "mime_type": "text/csv", "expected_bytes": 256},
    )
    assert a.status_code == 201, a.text
    aid = a.json()["id"]
    r = await b.client.post(
        "/v1/media-reservations/" + aid + "/upload-grant", headers=b.headers("teacher")
    )
    assert r.status_code == 200, r.text
    r = await b.client.post(
        "/v1/timetable-imports",
        headers=b.headers("teacher", key=key),
        json={
            "asset_id": aid,
            "term_id": b.ids["term"],
            "base_revision": revision,
            "byte_size": 256,
            "sha256": "c" * 64,
        },
    )
    assert r.status_code == 202, r.text
    imp = r.json()["resource_id"]
    jid = r.json()["job_id"]
    claim = await b.client.post("/internal/v1/jobs/claim", headers=b.wh)
    assert claim.status_code == 200 and claim.json()["id"] == jid, claim.text
    epoch = claim.json()["lease_epoch"]
    assert (
        await b.client.post(f"/internal/v1/jobs/{jid}/start", headers=b.wh, json={"epoch": epoch})
    ).status_code == 200
    day = date.today() + timedelta(days=1)
    row = {
        "entry_key": "demo-entry",
        "term_code": "DEMO-TERM",
        "course_code": "CS401",
        "branch": "CSE",
        "semester": "5",
        "section": "A",
        "teacher_email": "teacher@example.test",
        "room_code": "R1",
        "weekday": ["MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"][day.weekday()],
        "start_time": "09:00",
        "end_time": "10:00",
        "effective_from": day.isoformat(),
        "effective_until": (day + timedelta(days=30)).isoformat(),
        "timezone": "Asia/Kolkata",
    }
    result = await b.client.post(
        f"/internal/v1/jobs/{jid}/complete",
        headers=b.wh,
        json={
            "kind": "timetable",
            "epoch": epoch,
            "rows": rows or [row],
            "source_sha256": "c" * 64,
        },
    )
    assert result.status_code == 200, result.text
    preview = await b.client.get("/v1/timetable-imports/" + imp, headers=b.headers("teacher"))
    assert preview.status_code == 200, preview.text
    return preview.json(), day, row


async def test_timetable_preview_commit_reimport_and_tenant_boundary(bio):
    b = bio
    p, day, row = await import_ready(b)
    assert p["status"] == "ready", p
    body = {
        "preview_hash": p["preview_hash"],
        "expected_revision": 0,
        "materialize_date": day.isoformat(),
    }
    route = f"/v1/timetable-imports/{p['id']}/commit"
    wrong_day = {**body, "materialize_date": (day + timedelta(days=1)).isoformat()}
    no_occurrence = await b.client.post(
        route, headers=b.headers("teacher", key="wrong-day"), json=wrong_day
    )
    assert no_occurrence.status_code == 422, no_occurrence.text
    assert no_occurrence.json()["error"]["code"] == "NO_SESSION_ON_DATE"
    r = await b.client.post(route, headers=b.headers("teacher", key="commit"), json=body)
    assert r.status_code == 200, r.text
    assert r.json()["sessions_materialized"] == 1
    assert (
        await b.client.post(route, headers=b.headers("teacher", key="commit"), json=body)
    ).json() == r.json()
    assert (
        await b.client.get("/v1/timetable-imports/" + p["id"], headers=b.headers("other_teacher"))
    ).status_code in (403, 404)
    p2, _, _ = await import_ready(b, key="second", revision=1)
    r = await b.client.post(
        f"/v1/timetable-imports/{p2['id']}/commit",
        headers=b.headers("teacher", key="commit2"),
        json={
            "preview_hash": p2["preview_hash"],
            "expected_revision": 1,
            "materialize_date": day.isoformat(),
        },
    )
    assert r.status_code == 200, r.text
    with connect(b.urls["owner"]) as c:
        assert c.execute("SELECT count(*) FROM app.sessions").fetchone()[0] == 1
        assert c.execute("SELECT count(*) FROM app.schedule_series").fetchone()[0] == 1


async def test_timetable_rejects_overlaps_unknown_references_and_stale_preview(bio):
    b = bio
    p, day, row = await import_ready(b)
    # Validate overlapping keys against one another; never silently keep one row.
    bad = [row, {**row, "entry_key": "second-entry"}]
    overlap, _, _ = await import_ready(b, key="overlap", rows=bad)
    assert (
        overlap["status"] == "rejected"
        and overlap["preview_json"]["errors"][0]["code"] == "TIMETABLE_OVERLAP"
    )
    invalid, _, _ = await import_ready(b, key="invalid", rows=[{**row, "room_code": "UNKNOWN"}])
    assert invalid["status"] == "rejected"
    with connect(b.urls["owner"]) as c:
        c.execute(
            "UPDATE app.terms SET schedule_revision=schedule_revision+1 WHERE id=%s",
            (b.ids["term"],),
        )
    r = await b.client.post(
        f"/v1/timetable-imports/{p['id']}/commit",
        headers=b.headers("teacher", key="stale"),
        json={
            "preview_hash": p["preview_hash"],
            "expected_revision": 0,
            "materialize_date": day.isoformat(),
        },
    )
    assert r.status_code == 409
