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


def test_reports_show_binary_marks_and_leave_legacy_unmarked_rows_blank():
    assert [attendance_label(s) for s in ("present", "late", "absent", "excused", "unassessed")] == [
        "Present",
        "Present",
        "Absent",
        "",
        "",
    ]


def test_report_start_is_shown_in_india_time():
    from facetrack_worker.tabular import local_start

    assert local_start("2026-10-23T04:30:00+00:00") == "23 Oct 2026, 10:00 IST"
    assert local_start("2026-10-23T04:30:00Z") == "23 Oct 2026, 10:00 IST"
    assert local_start("not a date") == "not a date"


def test_report_file_cap_matches_api_base64_limit():
    from facetrack_worker.tabular import MAX_FILE_BYTES

    assert MAX_FILE_BYTES == 637500
    assert len(base64.b64encode(b"x" * MAX_FILE_BYTES)) == 850000
