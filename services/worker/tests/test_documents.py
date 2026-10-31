"""Actual bounded report rendering/CSV parsing on synthetic academic rows."""

import base64

import pytest

from facetrack_worker.tabular import COLUMNS, attendance_label, parse_csv, report


def test_report_preserves_ids_escapes_formulas_and_builds_multipage_pdf():
    snapshot = {
        "session_id": "synthetic-session",
        "starts_at": "2026-10-23T10:00:00+05:30",
        "kind": "final",
        "revision": 1,
        "incomplete": True,
        "institute_name": "Demo Institute",
        "course_code": "CS401",
        "course_title": "Data Structures",
        "branch": "CSE",
        "semester": 5,
        "section": "A",
        "term_code": "DEMO-TERM",
        "records": [
            {
                "enrollment_number": f"{n:04d}",
                "official_name": '=HYPERLINK("bad")'
                if n == 0
                else "Synthetic student & review <safe>",
                "status": "unassessed",
                "reason": "Reviewed note",
            }
            for n in range(120)
        ],
    }
    first = report(snapshot)
    second = report(snapshot)
    assert first == second
    csv = base64.b64decode(first["csv_base64"]).decode("utf-8-sig")
    pdf = base64.b64decode(first["pdf_base64"])
    assert "'0000" in csv and "'=HYPERLINK" in csv
    assert "Institute: Demo Institute" in csv and "Course: CS401" in csv
    assert pdf.startswith(b"%PDF-") and pdf.count(b"/Type /Page") > 2
    assert b"%%EOF" in pdf[-128:]


def test_csv_parser_enforces_contract_and_size(tmp_path):
    path = tmp_path / "input.csv"
    path.write_text(",".join(COLUMNS) + "\n" + ",".join(["value"] * len(COLUMNS)) + "\n")
    assert len(parse_csv(path)) == 1
    path.write_text("wrong,header\na,b\n")
    with pytest.raises(ValueError):
        parse_csv(path)
    path.write_bytes(b"x" * (1024 * 1024 + 1))
    with pytest.raises(ValueError):
        parse_csv(path)


def test_reports_use_three_final_attendance_states():
    assert [attendance_label(s) for s in ("present", "late", "absent", "excused", "unassessed")] == [
        "Present",
        "Present",
        "Absent",
        "Unassessed",
        "Unassessed",
    ]
