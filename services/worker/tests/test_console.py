"""Test Console behaviour with explicit synthetic fixtures; none of this measures recognition quality."""

import hashlib
import http.client
import json
import socket
import threading

import pytest

from facetrack_ml.config import canonical_hash
from facetrack_worker import console
from facetrack_worker.console import ConsoleError, ConsoleService, build_server

PROFILE = {
    "schema_version": 1, "calibration_id": "synthetic-console-test", "identity_threshold": 0.8,
    "minimum_margin": 0.1, "enrollment_consistency": 0.7,
}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


@pytest.fixture
def service(tmp_path, monkeypatch):
    models = tmp_path / "models"
    models.mkdir()
    for name, content in (("det.onnx", b"detector"), ("rec.onnx", b"recognizer"),
                          ("evidence.txt", b"synthetic evidence")):
        (models / name).write_bytes(content)
    manifest = {
        "release_id": "synthetic-console-test",
        "detector": {"file": "det.onnx", "sha256": sha(models / "det.onnx"), "source_url": "x",
                     "input_name": "input", "output_names": ["a"]},
        "recognizer": {"file": "rec.onnx", "sha256": sha(models / "rec.onnx"), "source_url": "x",
                       "input_name": "input", "output_names": ["b"]},
        "license": {"status": "approved", "intended_use": "local_poc",
                    "evidence_file": "evidence.txt", "evidence_sha256": sha(models / "evidence.txt"),
                    "reviewed_by": "test", "reviewed_at": "2026-10-26",
                    "permitted_uses": ["local_poc"]},
    }
    (models / "manifest.json").write_text(json.dumps(manifest))
    from facetrack_ml.config import load_manifest

    model_hash = canonical_hash(load_manifest(models / "manifest.json").model_dump())
    (tmp_path / "profile.json").write_text(json.dumps({**PROFILE, "model_hash": model_hash}))
    svc = ConsoleService(tmp_path / "console", models / "manifest.json", tmp_path / "profile.json")
    monkeypatch.setattr(svc, "_prepare_video", lambda path, enrollment: path)
    svc.calls = []

    def fake_cli(*args, timeout=300):
        svc.calls.append(args[0])
        if args[0] == "enrol":
            pid = args[args.index("--participant") + 1]
            (svc.engine / "templates").mkdir(parents=True, exist_ok=True)
            (svc.engine / "templates" / f"{pid}.enc").write_bytes(b"x")
            return {"template_count": 5}
        return svc.next_result

    svc.next_result = {"proposals": [], "quality": {}, "timings": {"processing_total_ms": 10}}
    monkeypatch.setattr(svc, "_cli", fake_cli)
    return svc


def clip(tmp_path, name="clip.webm"):
    path = tmp_path / name
    path.write_bytes(b"synthetic placeholder clip")
    return path


def enrol(svc, tmp_path, *labels):
    return [svc.enrol(label, clip(tmp_path), consent=True, supervised=True)["id"] for label in labels]


def result(*people):
    return {"proposals": [{"participant_id": p} for p in people],
            "quality": {"sampled_frames": 12, "detections": 20, "quality_rejects": 3},
            "unknown_observations": 1, "timings": {"processing_total_ms": 321.5}}


def test_enrolment_requires_both_confirmations_and_valid_label(service, tmp_path):
    with pytest.raises(ConsoleError) as error:
        service.enrol("Asha", clip(tmp_path), consent=True, supervised=False)
    assert error.value.code == "CONSENT_REQUIRED"
    with pytest.raises(ConsoleError) as error:
        service.enrol("<script>", clip(tmp_path), consent=True, supervised=True)
    assert error.value.code == "INVALID_LABEL"
    assert service.calls == []
    assert enrol(service, tmp_path, "Asha", "Ravi") == ["p01", "p02"]


def test_removed_volunteer_deletes_template_and_ids_are_not_reused(service, tmp_path):
    first, second = enrol(service, tmp_path, "Asha", "Ravi")
    service.remove_person(first)
    assert not (service.engine / "templates" / f"{first}.enc").exists()
    assert [p["id"] for p in service.list_people()] == [second]
    assert enrol(service, tmp_path, "Meera") == ["p03"]


@pytest.mark.parametrize("scenario,present,stranger,ok", [
    ("both_known", ["p01", "p02"], False, True),
    ("both_known", ["p01"], False, False),
    ("one_absent", ["p01"], False, True),
    ("one_absent", ["p01", "p02", "p03"], False, False),
    ("unknown_only", [], True, True),
    ("unknown_only", ["p01"], True, False),
    ("known_plus_unknown", ["p01"], True, True),
    ("known_plus_unknown", ["p01"], False, False),
    ("no_face", [], False, True),
    ("no_face", [], True, False),
    ("position_scale", ["p01", "p02"], False, True),
    ("made_up", [], False, False),
    ("both_known", ["p01", "p09"], False, False),
])
def test_ground_truth_must_match_the_scenario(service, tmp_path, scenario, present, stranger, ok):
    enrol(service, tmp_path, "A", "B", "C")
    if ok:
        service.run(scenario, present, stranger, clip(tmp_path))
    else:
        with pytest.raises(ConsoleError) as error:
            service.run(scenario, present, stranger, clip(tmp_path))
        assert error.value.status == 400


def test_needs_two_volunteers_before_any_scenario(service, tmp_path):
    enrol(service, tmp_path, "A")
    with pytest.raises(ConsoleError) as error:
        service.run("no_face", [], False, clip(tmp_path))
    assert error.value.code == "NEED_TWO_PEOPLE"


def test_scoring_separates_false_presence_from_misses_and_runs_fresh_repeats(service, tmp_path):
    enrol(service, tmp_path, "A", "B", "C")
    service.next_result = result("p01", "p03")  # p03 is wrongly suggested, p02 is missed
    row = service.run("both_known", ["p01", "p02"], False, clip(tmp_path))
    assert not row["correct"]
    assert row["false_presence"] == ["p03"] and row["missed"] == ["p02"]
    assert row["stable_across_repeats"] and service.calls.count("recognize") == console.REPEATS
    assert row["false_presence_names"] == ["C"]


def test_first_scored_attempt_is_official_and_rejections_are_preserved(service, tmp_path,
                                                                        monkeypatch):
    enrol(service, tmp_path, "A", "B")
    service.next_result = result("p01", "p02")
    service.run("both_known", ["p01", "p02"], False, clip(tmp_path))
    service.next_result = result()  # a later retry that would fail must not replace the first
    service.run("both_known", ["p01", "p02"], False, clip(tmp_path))

    def reject(*_a, **_k):
        raise ConsoleError("CLIP_TOO_SHORT")

    monkeypatch.setattr(service, "_prepare_video", lambda path, enrollment: reject())
    with pytest.raises(ConsoleError):
        service.run("no_face", [], False, clip(tmp_path))
    summary = service.summary()
    both = next(s for s in summary["scenarios"] if s["id"] == "both_known")
    nothing = next(s for s in summary["scenarios"] if s["id"] == "no_face")
    assert both["status"] == "pass" and both["attempts"] == 2
    assert nothing["status"] == "not_done" and nothing["rejected"] == 1
    assert summary["done"] == 1 and "In progress" in summary["verdict"]


def test_unstable_repeats_are_reported(service, tmp_path):
    enrol(service, tmp_path, "A", "B")
    outcomes = iter([result("p01"), result("p01"), result("p01", "p02")])
    service._cli = lambda *a, **k: next(outcomes)
    row = service.run("both_known", ["p01", "p02"], False, clip(tmp_path))
    assert row["stable_across_repeats"] is False
    assert service.summary()["all_stable"] is False


def test_full_set_gives_verdict_and_export_has_no_names_or_ids(service, tmp_path):
    enrol(service, tmp_path, "Secretname", "Other")
    truths = {"both_known": (["p01", "p02"], False), "one_absent": (["p01"], False),
              "unknown_only": ([], True), "known_plus_unknown": (["p02"], True),
              "position_scale": (["p01", "p02"], False), "no_face": ([], False)}
    for scenario, (present, stranger) in truths.items():
        service.next_result = result(*present)
        service.run(scenario, present, stranger, clip(tmp_path))
    summary = service.summary()
    assert summary["verdict"] == "All 6 scenarios matched what you expected."
    assert summary["passed"] == 6 and summary["false_presence_total"] == 0
    exported = json.dumps(service.summary(for_export=True))
    assert "Secretname" not in exported and "p01" not in exported and "p02" not in exported
    assert "not a guarantee" in summary["disclaimer"]
    report = service.summary(for_export=True)["report_text"]
    assert "RESULT: All 6 scenarios matched" in report
    assert "Scenarios matched: 6 of 6" in report and "false presence): 0" in report
    assert "Secretname" not in report and "p01" not in report and "p02" not in report


def test_integrity_flags_changed_model_or_profile(service):
    assert service.integrity()["ok"]
    (service.manifest.parent / "det.onnx").write_bytes(b"tampered")
    state = service.integrity()
    assert not state["ok"] and state["code"] == "MODEL_HASH_MISMATCH"


def test_integrity_pin_detects_profile_change_and_blocks_runs(service, tmp_path):
    enrol(service, tmp_path, "A", "B")
    data = json.loads(service.profile.read_text())
    data["identity_threshold"] = 0.5
    service.profile.write_text(json.dumps(data))
    state = service.integrity()
    assert not state["ok"] and "profile" in state["changed"]
    with pytest.raises(ConsoleError) as error:
        service.run("no_face", [], False, clip(tmp_path))
    assert error.value.code == "INTEGRITY"


def test_receipt_mismatch_is_detected(service, tmp_path):
    repo = tmp_path / "repo"
    (repo / "a").mkdir(parents=True)
    (repo / "a" / "f.txt").write_text("one")
    receipt = tmp_path / "receipt.json"
    receipt.write_text(json.dumps({"frozen_files_sha256": {
        "a/f.txt": sha(repo / "a" / "f.txt"), "gone/missing.txt": "0" * 64}}))
    service.receipt, service.repo_root = receipt, repo
    assert service.integrity()["receipt"] == {"checked": 1, "matched": 1}  # missing files are skipped
    (repo / "a" / "f.txt").write_text("changed")
    assert not service.integrity()["ok"]


def test_wipe_removes_volunteers_and_results(service, tmp_path):
    enrol(service, tmp_path, "A", "B")
    service.run("no_face", [], False, clip(tmp_path))
    service.wipe()
    assert service.list_people() == [] and service.summary()["done"] == 0
    assert not list((service.engine).glob("**/*.enc"))


# ---- HTTP layer ---------------------------------------------------------------------------
@pytest.fixture
def server(service, tmp_path):
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    web = tmp_path / "web"
    web.mkdir()
    (web / "index.html").write_text("<h1>console</h1>")
    (tmp_path / "secret.txt").write_text("outside")
    srv = build_server(service, web, "127.0.0.1", port, {"http://localhost:5303"})
    thread = threading.Thread(target=srv.serve_forever, daemon=True)
    thread.start()
    yield port
    srv.shutdown()
    srv.server_close()


def call(port, method, path, body=None, headers=None, host=None):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    send = {"Host": host or f"127.0.0.1:{port}", **(headers or {})}
    conn.request(method, path, body=body, headers=send)
    response = conn.getresponse()
    data = response.read()
    conn.close()
    return response.status, data, dict(response.getheaders())


def test_http_serves_page_status_and_blocks_foreign_hosts_origins_and_traversal(server):
    status, body, _ = call(server, "GET", "/")
    assert status == 200 and b"console" in body
    assert call(server, "GET", "/api/status")[0] == 200
    assert call(server, "GET", "/api/status", host="evil.example")[0] == 403
    assert call(server, "GET", "/api/status", headers={"Origin": "http://evil.example"})[0] == 403
    assert call(server, "GET", "/../secret.txt")[0] in (404, 200) and b"outside" not in \
        call(server, "GET", "/..%2Fsecret.txt")[1]
    status, _, headers = call(server, "GET", "/api/status", headers={"Origin": "http://localhost:5303"})
    assert status == 200 and headers["Access-Control-Allow-Origin"] == "http://localhost:5303"


def test_http_mutations_need_the_custom_header_and_clips_are_deleted(server, service):
    marker = {"X-FaceTrack-Console": "1", "Content-Type": "video/webm"}
    url = "/api/people/enrol?label=Asha&consent=1&supervised=1"
    assert call(server, "POST", url, b"abc", {"Content-Type": "video/webm"})[0] == 403
    assert call(server, "POST", url, b"abc", {**marker, "Content-Type": "text/plain"})[0] == 415
    status, body, _ = call(server, "POST", url, b"abc", marker)
    assert status == 200 and json.loads(body)["id"] == "p01"
    assert not [p for p in service.media.iterdir() if p.is_file()]
    status, body, _ = call(server, "POST", "/api/people/enrol?label=B", b"abc", marker)
    assert status == 400 and json.loads(body)["error"]["code"] == "CONSENT_REQUIRED"
    assert not [p for p in service.media.iterdir() if p.is_file()]
    assert call(server, "POST", "/api/wipe", None, {**marker, "Content-Length": "0"})[0] == 400


def test_http_rejects_oversized_uploads_before_reading(server):
    status, body, _ = call(server, "POST", "/api/runs?scenario=no_face", b"x",
                           {"X-FaceTrack-Console": "1", "Content-Type": "video/webm",
                            "Content-Length": str(console.MAX_RUN_BYTES + 1)})
    assert status == 413


def test_real_cli_errors_are_mapped_to_friendly_codes(service, tmp_path):
    real = ConsoleService(tmp_path / "real", service.manifest, service.profile)
    with pytest.raises(ConsoleError) as error:
        real._cli("probe", str(clip(tmp_path)))
    assert error.value.code == "INVALID_MEDIA"
    assert "could not be read" in error.value.message
