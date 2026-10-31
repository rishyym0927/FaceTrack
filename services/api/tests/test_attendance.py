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
            "status": "unassessed",
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


async def test_offering_attendance_summary_aggregates_and_is_teacher_only(bio):
    b = bio
    s = await open_session(b)
    sid = s["id"]
    close = await b.client.post(
        f"/v1/sessions/{sid}/close", headers=b.headers("teacher", key="c", version=s["version"])
    )
    s = close.json()
    pub = await b.client.post(
        f"/v1/sessions/{sid}/finalize",
        headers=b.headers("teacher", key="pub", version=s["version"]),
        json={
            "decisions": [
                {"student_id": b.ids["student1_profile"], "status": "present", "reason": "seen"}
            ]
        },
    )
    assert pub.status_code == 200, pub.text
    offering = b.ids["offering"]
    data = (
        await b.client.get(
            f"/v1/offerings/{offering}/attendance-summary", headers=b.headers("teacher")
        )
    ).json()
    assert data["sessions_conducted"] == 1 and len(data["students"]) == 1
    row = data["students"][0]
    assert row["present"] == 1 and row["attended"] == 1 and row["assessed"] == 1
    assert row["percentage"] == 100.0 and row["conducted"] == 1
    # Only the assigned teacher (or an admin) may see the cumulative view.
    for label in ("student1", "unassigned", "other_teacher"):
        denied = await b.client.get(
            f"/v1/offerings/{offering}/attendance-summary", headers=b.headers(label)
        )
        assert denied.status_code in (403, 404), denied.text
    # A correction updates the aggregate automatically (no recompute call needed).
    current = (await b.client.get(f"/v1/sessions/{sid}", headers=b.headers("teacher"))).json()
    corr = await b.client.post(
        f"/v1/sessions/{sid}/corrections",
        headers=b.headers("teacher", key="corr", version=current["version"]),
        json={
            "student_id": b.ids["student1_profile"],
            "status": "unassessed",
            "reason": "Approved leave",
            "publication_revision": 1,
        },
    )
    assert corr.status_code == 200, corr.text
    after = (
        await b.client.get(
            f"/v1/offerings/{offering}/attendance-summary", headers=b.headers("teacher")
        )
    ).json()["students"][0]
    assert after["unassessed"] == 1 and after["present"] == 0
    assert after["assessed"] == 0 and after["percentage"] is None
    # Only Present, Absent and Unassessed can be recorded now.
    current = (await b.client.get(f"/v1/sessions/{sid}", headers=b.headers("teacher"))).json()
    for legacy in ("late", "excused"):
        refused = await b.client.post(
            f"/v1/sessions/{sid}/corrections",
            headers=b.headers("teacher", key=f"legacy-{legacy}", version=current["version"]),
            json={
                "student_id": b.ids["student1_profile"],
                "status": legacy,
                "reason": "Legacy status",
                "publication_revision": 2,
            },
        )
        assert refused.status_code == 422, refused.text


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
                    "status": "absent",
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
    assert byid[b.ids["student1_profile"]]["status"] == "absent"
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


async def test_teacher_confirms_absence_and_student_disputes_latest_publication(bio):
    b = bio
    s = await recognition_ready(b)
    _, jid, epoch, data = await captured(b, s)
    known = data["roster"][0]
    body = {
        k: data[k]
        for k in ("generation", "source_sha256", "model_hash", "profile_hash", "roster_hash")
    }
    body.update(
        epoch=epoch,
        processed_sha256="e" * 64,
        proposals=[
            {
                "student_id": known["student_id"],
                "template_set_id": known["template_set_id"],
                "template_epoch": known["template_epoch"],
                "hits": 3,
                "span_ms": 700,
                "similarity": 0.91,
            }
        ],
        unknown_observations=2,
        quality={"sampled_frames": 12, "detections": 5, "quality_rejects": 1},
        timings={"processing_total_ms": 5},
    )
    assert (
        await b.client.post(f"/internal/v1/jobs/{jid}/complete", headers=b.wh, json=body)
    ).status_code == 200
    attendance = (
        await b.client.get(f"/v1/sessions/{s['id']}/attendance", headers=b.headers("teacher"))
    ).json()
    rows = {x["student_id"]: x for x in attendance["items"]}
    absent_id = next(x for x in rows if x != known["student_id"])
    assert rows[known["student_id"]]["status"] == "proposed_present"
    assert rows[absent_id]["status"] == "proposed_absent"
    assert rows[absent_id]["assessment_code"] == "not_recognized"

    closed = await b.client.post(
        f"/v1/sessions/{s['id']}/close",
        headers=b.headers("teacher", key="close-absence", version=attendance["session"]["version"]),
    )
    assert closed.status_code == 200, closed.text
    rejected = await b.client.post(
        f"/v1/sessions/{s['id']}/finalize",
        headers=b.headers("teacher", key="unresolved", version=closed.json()["version"]),
        json={"decisions": []},
    )
    assert rejected.status_code == 409 and rejected.json()["error"]["code"] == "REVIEW_REQUIRED"
    publication = await b.client.post(
        f"/v1/sessions/{s['id']}/finalize",
        headers=b.headers("teacher", key="confirm-absence", version=closed.json()["version"]),
        json={
            "decisions": [
                {"student_id": known["student_id"], "status": "present"},
                {"student_id": absent_id, "status": "absent"},
            ]
        },
    )
    assert publication.status_code == 200, publication.text
    absent_label = "student1" if absent_id == b.ids["student1_profile"] else "student2"
    blank_reason = await b.client.post(
        f"/v1/me/attendance/{publication.json()['id']}/disputes",
        headers=b.headers(absent_label, key="blank-attendance-query"),
        json={"reason": "     "},
    )
    assert blank_reason.status_code == 422
    dispute = await b.client.post(
        f"/v1/me/attendance/{publication.json()['id']}/disputes",
        headers=b.headers(absent_label, key="attendance-query"),
        json={"reason": "I attended this class and request a review."},
    )
    assert dispute.status_code == 201, dispute.text
    did = dispute.json()["id"]
    replayed_dispute = await b.client.post(
        f"/v1/me/attendance/{publication.json()['id']}/disputes",
        headers=b.headers(absent_label, key="attendance-query"),
        json={"reason": "I attended this class and request a review."},
    )
    assert replayed_dispute.status_code == 201
    assert replayed_dispute.json()["id"] == did
    assert (
        await b.client.get("/v1/me/attendance-disputes", headers=b.headers(absent_label))
    ).json()["items"][0]["status"] == "open"
    for label in ("student1", "unassigned", "other_teacher"):
        denied = await b.client.get(
            f"/v1/offerings/{b.ids['offering']}/attendance-disputes",
            headers=b.headers(label),
        )
        assert denied.status_code in (403, 404)
    blank_resolution = await b.client.post(
        f"/v1/attendance-disputes/{did}/resolve",
        headers=b.headers("teacher", key="blank-query-resolution", version=1),
        json={"decision": "rejected", "reason": "   "},
    )
    assert blank_resolution.status_code == 422
    resolved = await b.client.post(
        f"/v1/attendance-disputes/{did}/resolve",
        headers=b.headers("teacher", key="accept-query", version=1),
        json={"decision": "accepted", "reason": "Attendance verified with the faculty."},
    )
    assert resolved.status_code == 200, resolved.text
    assert resolved.json()["status"] == "accepted"
    replayed_resolution = await b.client.post(
        f"/v1/attendance-disputes/{did}/resolve",
        headers=b.headers("teacher", key="accept-query", version=1),
        json={"decision": "accepted", "reason": "Attendance verified with the faculty."},
    )
    assert replayed_resolution.status_code == 200
    assert replayed_resolution.json()["resolved_publication_id"] == resolved.json()[
        "resolved_publication_id"
    ]
    own = (await b.client.get("/v1/me/attendance", headers=b.headers(absent_label))).json()
    assert own["items"][0]["status"] == "present"
    assert own["items"][0]["revision"] == 2


async def test_limited_capture_never_proposes_absence(bio):
    b = bio
    s = await recognition_ready(b)
    _, jid, epoch, data = await captured(b, s)
    body = {
        k: data[k]
        for k in ("generation", "source_sha256", "model_hash", "profile_hash", "roster_hash")
    }
    body.update(
        epoch=epoch,
        processed_sha256="f" * 64,
        proposals=[],
        unknown_observations=0,
        quality={"sampled_frames": 12, "detections": 4, "quality_rejects": 4},
        timings={"processing_total_ms": 4},
    )
    result = await b.client.post(
        f"/internal/v1/jobs/{jid}/complete", headers=b.wh, json=body
    )
    assert result.status_code == 200, result.text
    rows = (
        await b.client.get(f"/v1/sessions/{s['id']}/attendance", headers=b.headers("teacher"))
    ).json()["items"]
    assert all(x["status"] == "unassessed" for x in rows)
    assert all(x["assessment_code"] == "limited_capture" for x in rows)


async def test_session_list_is_newest_first_across_cursor_pages(bio):
    b = bio
    base = datetime.now(timezone.utc).replace(microsecond=0)
    created = []
    for n, days in enumerate((-3, -1, -5, -2)):
        start = base + timedelta(days=days)
        r = await b.client.post(
            "/v1/sessions",
            headers=b.headers("teacher", key=f"order-{n}"),
            json={
                "offering_id": b.ids["offering"],
                "starts_at": start.isoformat(),
                "ends_at": (start + timedelta(hours=1)).isoformat(),
            },
        )
        assert r.status_code == 201, r.text
        created.append(r.json())
    expected = [s["id"] for s in sorted(created, key=lambda s: s["starts_at"], reverse=True)]
    seen, cursor = [], None
    for _ in range(3):
        params = {"offering_id": b.ids["offering"], "limit": 2}
        if cursor:
            params["cursor"] = cursor
        r = await b.client.get("/v1/sessions", headers=b.headers("teacher"), params=params)
        assert r.status_code == 200, r.text
        body = r.json()
        seen += [s["id"] for s in body["items"]]
        cursor = body["next_cursor"]
        if cursor is None:
            break
        assert cursor == body["items"][-1]["id"]
    assert seen == expected


async def test_own_attendance_is_newest_first_across_cursor_pages(bio):
    b = bio
    base = datetime.now(timezone.utc)
    published = []
    for n in range(3):
        r = await b.client.post(
            "/v1/sessions",
            headers=b.headers("teacher", key=f"own-{n}"),
            json={
                "offering_id": b.ids["offering"],
                "starts_at": (base - timedelta(minutes=n + 1)).isoformat(),
                "ends_at": (base + timedelta(hours=1)).isoformat(),
            },
        )
        assert r.status_code == 201, r.text
        s = r.json()
        sid = s["id"]
        for step in ("open", "close"):
            r = await b.client.post(
                f"/v1/sessions/{sid}/{step}",
                headers=b.headers("teacher", key=f"{step}-{n}", version=s["version"]),
            )
            assert r.status_code == 200, r.text
            s = r.json()
        r = await b.client.post(
            f"/v1/sessions/{sid}/finalize",
            headers=b.headers("teacher", key=f"pub-{n}", version=s["version"]),
            json={
                "decisions": [
                    {"student_id": b.ids["student1_profile"], "status": "present", "reason": "seen"}
                ]
            },
        )
        assert r.status_code == 200, r.text
        published.append(sid)
    seen, cursor = [], None
    for _ in range(3):
        params = {"limit": 1, **({"cursor": cursor} if cursor else {})}
        r = await b.client.get("/v1/me/attendance", headers=b.headers("student1"), params=params)
        assert r.status_code == 200, r.text
        body = r.json()
        # The summary always covers every published session, not just this page.
        assert body["summary"]["assessed"] == 3 and len(body["items"]) == 1
        seen.append(body["items"][0])
        cursor = body["next_cursor"]
        if cursor is None:
            break
        assert cursor == body["items"][-1]["id"]
    # Session n started n+1 minutes ago, so class-date order is creation order.
    assert [x["session_id"] for x in seen] == published
    starts = [x["starts_at"] for x in seen]
    assert starts == sorted(starts, reverse=True)


async def test_own_attendance_paging_survives_correction_and_keeps_class_order(bio):
    b = bio
    base = datetime.now(timezone.utc)
    sids = []
    for n in range(3):
        r = await b.client.post(
            "/v1/sessions",
            headers=b.headers("teacher", key=f"fix-{n}"),
            json={
                "offering_id": b.ids["offering"],
                "starts_at": (base - timedelta(minutes=n + 1)).isoformat(),
                "ends_at": (base + timedelta(hours=1)).isoformat(),
            },
        )
        s = r.json()
        for step in ("open", "close"):
            s = (
                await b.client.post(
                    f"/v1/sessions/{s['id']}/{step}",
                    headers=b.headers("teacher", key=f"fix-{step}-{n}", version=s["version"]),
                )
            ).json()
        r = await b.client.post(
            f"/v1/sessions/{s['id']}/finalize",
            headers=b.headers("teacher", key=f"fix-pub-{n}", version=s["version"]),
            json={
                "decisions": [
                    {"student_id": b.ids["student1_profile"], "status": "present", "reason": "seen"}
                ]
            },
        )
        assert r.status_code == 200, r.text
        sids.append(s["id"])
    first = (
        await b.client.get("/v1/me/attendance", headers=b.headers("student1"), params={"limit": 1})
    ).json()
    assert first["items"][0]["session_id"] == sids[0]
    # Correct the session the cursor points at before loading the next page.
    current = (await b.client.get(f"/v1/sessions/{sids[0]}", headers=b.headers("teacher"))).json()
    r = await b.client.post(
        f"/v1/sessions/{sids[0]}/corrections",
        headers=b.headers("teacher", key="fix-corr", version=current["version"]),
        json={
            "student_id": b.ids["student1_profile"],
            "status": "absent",
            "reason": "Approved leave",
            "publication_revision": 1,
        },
    )
    assert r.status_code == 200, r.text
    rest = (
        await b.client.get(
            "/v1/me/attendance",
            headers=b.headers("student1"),
            params={"limit": 5, "cursor": first["next_cursor"]},
        )
    ).json()
    assert [x["session_id"] for x in rest["items"]] == sids[1:]
    # The corrected session keeps its class-date place instead of jumping to the top.
    everything = (await b.client.get("/v1/me/attendance", headers=b.headers("student1"))).json()
    assert [x["session_id"] for x in everything["items"]] == sids
    assert everything["items"][0]["revision"] == 2
