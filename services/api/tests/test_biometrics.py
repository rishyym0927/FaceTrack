"""Real PostgreSQL state/permissions; explicitly synthetic media and vectors."""

import hashlib
import json
from uuid import UUID, uuid4

import pytest
from pydantic import SecretStr

from tools.seed import connect


@pytest.fixture
async def bio(backend):
    b = backend
    await b.claim()
    await b.claim("student2", "0002", key="second")
    b.settings.template_keys = {"v1": SecretStr("34" * 32)}
    model, profile, worker = uuid4(), uuid4(), uuid4()
    token = "ftw_synthetic_fixture"
    with connect(b.urls["owner"]) as c:
        c.execute(
            "INSERT INTO app.model_releases(id,institute_id,manifest_json,manifest_hash,license_status) VALUES(%s,%s,'{}',%s,'academic_local_only')",
            (model, b.ids["institute"], "a" * 64),
        )
        c.execute(
            "INSERT INTO app.recognition_profiles(id,institute_id,model_release_id,settings_json,settings_hash) VALUES(%s,%s,%s,'{}',%s)",
            (profile, b.ids["institute"], model, "b" * 64),
        )
        c.execute(
            "INSERT INTO app.worker_identities(id,institute_id,token_hash,allowed_model_hashes,expires_at) VALUES(%s,%s,%s,%s,now()+interval '1 day')",
            (
                worker,
                b.ids["institute"],
                hashlib.sha256(token.encode()).hexdigest(),
                json.dumps(["a" * 64]),
            ),
        )
        c.execute(
            "INSERT INTO app.course_enrollments(institute_id,offering_id,student_id,status) VALUES(%s,%s,%s,'active')",
            (b.ids["institute"], b.ids["offering"], b.ids["student1_profile"]),
        )

    async def upload(a):
        return {
            "token": "synthetic",
            "bucket": a["bucket"],
            "object_key": a["object_key"],
            "tus_url": "https://fixture.invalid/upload",
            "reservation_expires_at": a["reservation_expires_at"],
        }

    async def info(a):
        return {"size": a["expected_bytes"], "mime_type": a["mime_type"]}

    async def download(a):
        return "https://fixture.invalid/video"

    async def delete(a):
        pass

    for name, value in [
        ("upload", upload),
        ("info", info),
        ("download", download),
        ("delete", delete),
    ]:
        setattr(b.app.state.storage, name, value)
    b.wh = {"Authorization": "Bearer " + token}
    return b


async def reserve(b, key="one"):
    notice = (await b.client.get("/v1/privacy/notice")).json()
    c = await b.client.post(
        "/v1/consents",
        headers=b.headers("student1", key=key + "consent"),
        json={"notice_version": notice["version"], "notice_hash": notice["hash"]},
    )
    assert c.status_code == 201, c.text
    a = await b.client.post(
        "/v1/biometric-enrollments",
        headers=b.headers("student1", key=key),
        json={"consent_id": c.json()["id"], "mime_type": "video/webm", "expected_bytes": 256},
    )
    assert a.status_code == 201, a.text
    return a.json(), c.json()["id"]


async def queue(b, key="one"):
    a, c = await reserve(b, key)
    r = await b.client.post(
        f"/v1/biometric-enrollments/{a['id']}/upload-grant",
        headers=b.headers("student1"),
        json={"mime_type": "video/webm", "expected_bytes": 256},
    )
    assert r.status_code == 200, r.text
    url = f"/v1/biometric-enrollments/{a['id']}/upload-complete"
    payload = {"asset_id": a["asset_id"], "byte_size": 256, "sha256": "c" * 64}
    r = await b.client.post(url, headers=b.headers("student1", key=key + "upload"), json=payload)
    assert r.status_code == 202, r.text
    duplicate = await b.client.post(
        url, headers=b.headers("student1", key=key + "upload"), json=payload
    )
    assert duplicate.json() == r.json()
    return a, c, r.json()["job_id"]


async def process(b, key="one"):
    a, c, j = await queue(b, key)
    r = await b.client.post("/internal/v1/jobs/claim", headers=b.wh)
    assert r.status_code == 200, r.text
    epoch = r.json()["lease_epoch"]
    r = await b.client.post(f"/internal/v1/jobs/{j}/start", headers=b.wh, json={"epoch": epoch})
    assert r.status_code == 200, r.text
    assert (
        await b.client.get(f"/internal/v1/jobs/{j}/input?epoch={epoch}", headers=b.wh)
    ).status_code == 200
    body = {
        "epoch": epoch,
        "generation": 1,
        "source_sha256": "c" * 64,
        "processed_sha256": "d" * 64,
        "model_hash": "a" * 64,
        "profile_hash": "b" * 64,
        "quality": {"detections": 5},
        "timings": {"total_ms": 1.0},
        "templates": [
            {"ordinal": n, "pose": "unverified", "vector": [1.0] + [0.0] * 511} for n in range(3)
        ],
    }
    r = await b.client.post(f"/internal/v1/jobs/{j}/complete", headers=b.wh, json=body)
    assert r.status_code == 200, r.text
    return a, c, j, body


async def test_owner_consent_and_worker_auth(bio):
    b = bio
    a, c = await reserve(b)
    assert a["pose_order"][0] == "front" and set(a["pose_order"]) == {
        "front",
        "up",
        "down",
        "left",
        "right",
    }
    for label in ("student2", "unassigned"):
        assert (
            await b.client.get(f"/v1/biometric-enrollments/{a['id']}", headers=b.headers(label))
        ).status_code in (403, 404)
    r = await b.client.post(
        "/v1/biometric-enrollments",
        headers=b.headers("student2"),
        json={"consent_id": c, "mime_type": "video/webm", "expected_bytes": 256},
    )
    assert r.status_code == 409
    assert (await b.client.post("/internal/v1/jobs/claim", headers=b.headers())).status_code == 401
    other = await b.client.get(
        f"/v1/biometric-enrollments/{a['id']}",
        headers=b.headers("other_teacher", institute=b.ids["other_institute"]),
    )
    assert other.status_code == 404


async def test_idempotence_and_one_unfinished(bio):
    b = bio
    a, _ = await reserve(b)
    duplicate, _ = await reserve(b)
    assert a["id"] == duplicate["id"]
    notice = (
        await b.client.get("/v1/me/biometric-enrollment", headers=b.headers("student1"))
    ).json()
    r = await b.client.post(
        "/v1/biometric-enrollments",
        headers=b.headers("student1", key="different"),
        json={
            "consent_id": notice["consent"]["id"],
            "mime_type": "video/webm",
            "expected_bytes": 256,
        },
    )
    assert r.status_code == 409


async def test_encryption_review_and_withdrawal(bio):
    b = bio
    a, c, j, body = await process(b)
    url = f"/internal/v1/jobs/{j}/complete"
    assert (await b.client.post(url, headers=b.wh, json=body)).status_code == 200
    body["processed_sha256"] = "e" * 64
    assert (await b.client.post(url, headers=b.wh, json=body)).status_code == 409
    state = (
        await b.client.get("/v1/me/biometric-enrollment", headers=b.headers("student1"))
    ).json()
    assert state["attempt"]["status"] == "review_required" and not state["active_sets"]
    assert "vector" not in json.dumps(state) and "ciphertext" not in json.dumps(state)
    for label in ("student2", "unassigned", "other_teacher"):
        assert (
            await b.client.get(
                f"/v1/biometric-enrollments/{a['id']}/review-video", headers=b.headers(label)
            )
        ).status_code in (403, 404)
    with connect(b.urls["owner"]) as conn:
        rows = conn.execute("SELECT ciphertext,nonce FROM app.face_templates").fetchall()
        assert len(rows) == 3 and all(
            len(x[1]) == 12 and not bytes(x[0]).startswith(b"[") for x in rows
        )
    r = await b.client.post(
        f"/v1/biometric-enrollments/{a['id']}/approve",
        headers=b.headers(version=state["attempt"]["version"], key="approval"),
        json={"identity_confirmed": True, "poses_confirmed": True},
    )
    assert r.status_code == 200, r.text
    with connect(b.urls["owner"]) as conn:
        assert conn.execute("SELECT count(*) FROM app.face_templates").fetchone()[0] == 3
    assert (
        await b.client.delete("/v1/consents/" + c, headers=b.headers("student1"))
    ).status_code == 200
    with connect(b.urls["owner"]) as conn:
        assert conn.execute("SELECT count(*) FROM app.face_templates").fetchone()[0] == 0
        assert (
            conn.execute("SELECT count(*) FROM app.template_sets WHERE status='active'").fetchone()[
                0
            ]
            == 0
        )


async def test_lease_expiry_reclaim_and_withdrawal(bio):
    b = bio
    a, c, j = await queue(b)
    r = await b.client.post("/internal/v1/jobs/claim", headers=b.wh)
    assert r.status_code == 200, r.text
    epoch = r.json()["lease_epoch"]
    assert (await b.client.post("/internal/v1/jobs/claim", headers=b.wh)).status_code == 204
    with connect(b.urls["owner"]) as conn:
        conn.execute(
            "UPDATE app.jobs SET lease_expires_at=now()-interval '1 second' WHERE id=%s", (UUID(j),)
        )
    assert (
        await b.client.post(f"/internal/v1/jobs/{j}/heartbeat", headers=b.wh, json={"epoch": epoch})
    ).status_code == 409
    r = await b.client.post("/internal/v1/maintenance/reconcile", headers=b.wh)
    assert r.status_code == 200, r.text
    with connect(b.urls["owner"]) as conn:
        conn.execute("UPDATE app.jobs SET available_at=now() WHERE id=%s", (UUID(j),))
    r = await b.client.post("/internal/v1/jobs/claim", headers=b.wh)
    assert r.status_code == 200, r.text
    assert r.json()["lease_epoch"] == epoch + 1
    assert (
        await b.client.delete("/v1/consents/" + c, headers=b.headers("student1"))
    ).status_code == 200
    assert (
        await b.client.get(f"/internal/v1/jobs/{j}/input?epoch={epoch + 1}", headers=b.wh)
    ).status_code == 409


async def test_upload_metadata_immutable_and_expiry(bio):
    b = bio
    a, _ = await reserve(b)
    url = f"/v1/biometric-enrollments/{a['id']}/upload-grant"
    assert (
        await b.client.post(
            url,
            headers=b.headers("student1"),
            json={"mime_type": "video/webm", "expected_bytes": 200},
        )
    ).status_code == 200
    assert (
        await b.client.post(
            url,
            headers=b.headers("student1"),
            json={"mime_type": "video/webm", "expected_bytes": 201},
        )
    ).status_code == 409
    with connect(b.urls["owner"]) as conn:
        conn.execute("UPDATE app.media_assets SET reservation_expires_at=now()-interval '1 second'")
    assert (
        await b.client.post(
            url,
            headers=b.headers("student1"),
            json={"mime_type": "video/webm", "expected_bytes": 200},
        )
    ).status_code == 409
    assert (
        await b.client.post("/internal/v1/maintenance/reconcile", headers=b.wh)
    ).status_code == 200
    state = (
        await b.client.get("/v1/me/biometric-enrollment", headers=b.headers("student1"))
    ).json()
    assert state["attempt"]["status"] == "expired"


async def test_replacement_rejection_preserves_active_and_withdraws_all_consents(bio):
    b = bio
    first, _, _, _ = await process(b, "first")
    view = (await b.client.get("/v1/me/biometric-enrollment", headers=b.headers("student1"))).json()
    approval = {"identity_confirmed": True, "poses_confirmed": True}
    r = await b.client.post(
        f"/v1/biometric-enrollments/{first['id']}/approve",
        headers=b.headers(version=view["attempt"]["version"], key="activate-first"),
        json=approval,
    )
    assert r.status_code == 200, r.text
    second, consent, _, _ = await process(b, "replacement")
    state = (
        await b.client.get("/v1/me/biometric-enrollment", headers=b.headers("student1"))
    ).json()
    assert len(state["active_sets"]) == 1
    r = await b.client.post(
        f"/v1/biometric-enrollments/{second['id']}/reject",
        headers=b.headers(version=state["attempt"]["version"], key="reject-replacement"),
        json={"reason": "Please show the complete guided poses."},
    )
    assert r.status_code == 200, r.text
    with connect(b.urls["owner"]) as c:
        assert (
            c.execute("SELECT count(*) FROM app.template_sets WHERE status='active'").fetchone()[0]
            == 1
        )
        assert c.execute("SELECT count(*) FROM app.face_templates").fetchone()[0] == 3
    assert (
        await b.client.delete("/v1/consents/" + consent, headers=b.headers("student1"))
    ).status_code == 200
    with connect(b.urls["owner"]) as c:
        assert c.execute("SELECT count(*) FROM app.face_templates").fetchone()[0] == 0
        assert (
            c.execute("SELECT count(*) FROM app.consents WHERE withdrawn_at IS NULL").fetchone()[0]
            == 0
        )


async def test_completion_replay_survives_deleted_raw_object(bio):
    b = bio
    a, _, job = await queue(b)
    from app.errors import APIError

    async def missing(asset):
        raise APIError(409, "MEDIA_NOT_AVAILABLE", "Video deleted")

    b.app.state.storage.info = missing
    response = await b.client.post(
        f"/v1/biometric-enrollments/{a['id']}/upload-complete",
        headers=b.headers("student1", key="oneupload"),
        json={"asset_id": a["asset_id"], "byte_size": 256, "sha256": "c" * 64},
    )
    assert response.status_code == 202, response.text
    assert response.json()["job_id"] == job


async def test_invalid_vectors_and_stale_teacher_review(bio):
    b = bio
    a, _, job, body = await process(b)
    body["templates"][0]["vector"] = [0.0] * 512
    assert (
        await b.client.post(f"/internal/v1/jobs/{job}/complete", headers=b.wh, json=body)
    ).status_code == 422
    r = await b.client.post(
        f"/v1/biometric-enrollments/{a['id']}/approve",
        headers=b.headers(version=1, key="stale"),
        json={"identity_confirmed": True, "poses_confirmed": True},
    )
    assert r.status_code == 409
    assert (await b.client.get("/v1/jobs/" + job, headers=b.headers("student2"))).status_code == 404


async def test_teacher_review_list_first_page_and_cursor(bio):
    b = bio
    route = f"/v1/offerings/{b.ids['offering']}/biometric-enrollments"
    empty = await b.client.get(route, headers=b.headers("teacher"))
    assert empty.status_code == 200, empty.text
    assert empty.json() == {"items": [], "next_cursor": None}
    attempt, _, _, _ = await process(b)
    result = await b.client.get(route, headers=b.headers("teacher"))
    assert result.status_code == 200, result.text
    assert [row["id"] for row in result.json()["items"]] == [attempt["id"]]
    assert result.json()["items"][0]["status"] == "review_required"
    next_page = await b.client.get(
        route, headers=b.headers("teacher"), params={"cursor": attempt["id"]}
    )
    assert next_page.status_code == 200, next_page.text
    assert next_page.json()["items"] == []
    for label in ["student1", "unassigned", "other_teacher"]:
        denied = await b.client.get(route, headers=b.headers(label))
        assert denied.status_code in (403, 404), denied.text
