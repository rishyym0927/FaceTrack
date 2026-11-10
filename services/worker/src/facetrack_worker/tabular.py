"""Bounded non-biometric report rendering and CSV syntax parsing."""

import base64
import csv
import io
from datetime import datetime, timedelta, timezone
from xml.sax.saxutils import escape

# The API caps each base64 field at 850,000 characters: 4 * ceil(n / 3) <= 850,000.
MAX_FILE_BYTES = 850000 // 4 * 3

try:
    from zoneinfo import ZoneInfo

    KOLKATA = ZoneInfo("Asia/Kolkata")
except Exception:  # No tz database in the image; India has had no DST since 1945.
    KOLKATA = timezone(timedelta(hours=5, minutes=30), "IST")

COLUMNS = [
    "entry_key",
    "term_code",
    "course_code",
    "branch",
    "semester",
    "section",
    "teacher_email",
    "room_code",
    "weekday",
    "start_time",
    "end_time",
    "effective_from",
    "effective_until",
    "timezone",
]


def parse_csv(path):
    if path.stat().st_size > 1024 * 1024:
        raise ValueError("CSV exceeds 1 MiB.")
    with path.open(encoding="utf-8-sig", newline="") as stream:
        rows = csv.DictReader(stream)
        if rows.fieldnames != COLUMNS:
            raise ValueError("Use the exact timetable CSV columns and order.")
        result = []
        for row in rows:
            if (
                len(result) >= 500
                or None in row
                or any(v is None or len(v) > 254 for v in row.values())
            ):
                raise ValueError("Invalid CSV row or more than 500 rows.")
            result.append({k: v.strip() for k, v in row.items()})
    if not result:
        raise ValueError("Timetable CSV is empty.")
    return result


def local_start(value):
    """Session start as Asia/Kolkata wall time; unparseable input is shown unchanged."""
    try:
        moment = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return str(value)
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=timezone.utc)
    return moment.astimezone(KOLKATA).strftime("%d %b %Y, %H:%M IST")


def safe(value):
    text = str(value or "")
    return (
        "'" + text
        if text.lstrip().startswith(("=", "+", "-", "@"))
        or (text.isdigit() and text.startswith("0"))
        else text
    )


def attendance_label(status):
    """Format binary marks and distinguish suggestions in draft reports."""
    return {
        "present": "Present",
        "late": "Present",
        "absent": "Absent",
        "proposed_present": "Present (draft)",
        "proposed_absent": "Absent (draft)",
    }.get(status, "")


def report(snapshot):
    from pathlib import Path

    import pandas as pd

    # ReportLab's bundled Vera font gives consistent Latin/Greek/Cyrillic coverage; deployment font coverage remains a release check.
    import reportlab
    from reportlab.lib import colors
    from reportlab.lib.pagesizes import A4
    from reportlab.lib.styles import getSampleStyleSheet
    from reportlab.pdfbase import pdfmetrics
    from reportlab.pdfbase.ttfonts import TTFont
    from reportlab.platypus import LongTable, Paragraph, SimpleDocTemplate, Spacer, TableStyle

    font = Path(reportlab.__file__).parent / "fonts/Vera.ttf"
    if "FaceTrackVera" not in pdfmetrics.getRegisteredFontNames():
        pdfmetrics.registerFont(TTFont("FaceTrackVera", str(font)))
    entries = [
        {
            "Enrolment number": safe(r["enrollment_number"]),
            "Student": safe(r["official_name"]),
            "Attendance": attendance_label(r["status"]),
            "Teacher note": safe(r.get("reason")),
        }
        for r in snapshot["records"]
    ]
    frame = pd.DataFrame(
        entries, columns=["Enrolment number", "Student", "Attendance", "Teacher note"]
    )
    def label(value):
        return safe(value).replace("\n", " ").replace("\r", " ").replace(",", " ")
    meta = (
        f"Session: {snapshot['session_id']} | {snapshot.get('kind', 'final')} | "
        f"Revision: {snapshot.get('revision', 0)} | Policy: session-v1 | "
        f"{'INCOMPLETE' if snapshot.get('incomplete') else 'Complete'} | "
        f"Institute: {label(snapshot.get('institute_name'))} | "
        f"Course: {label(snapshot.get('course_code'))} {label(snapshot.get('course_title'))} | "
        f"Group: {label(snapshot.get('branch'))} semester {label(snapshot.get('semester'))} "
        f"section {label(snapshot.get('section'))} | Term: {label(snapshot.get('term_code'))}"
    )
    csv_bytes = ("# " + meta + "\n" + frame.to_csv(index=False)).encode("utf-8-sig")
    output = io.BytesIO()
    styles = getSampleStyleSheet()
    styles["Normal"].fontName = "FaceTrackVera"
    styles["Normal"].fontSize = 8
    styles["Normal"].leading = 11
    title = Paragraph("FaceTrack Attendance Report", styles["Heading1"])
    table = [[Paragraph(escape(c), styles["Normal"]) for c in frame.columns]]
    for row in snapshot["records"]:
        table.append(
            [
                Paragraph(escape(str(v or "")), styles["Normal"])
                for v in [
                    row["enrollment_number"],
                    row["official_name"],
                    attendance_label(row["status"]),
                    row.get("reason"),
                ]
            ]
        )
    grid = LongTable(table, colWidths=[85, 150, 80, 180], repeatRows=1, hAlign="LEFT")
    grid.setStyle(
        TableStyle(
            [
                ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#e6f1ed")),
                ("VALIGN", (0, 0), (-1, -1), "TOP"),
                ("GRID", (0, 0), (-1, -1), 0.3, colors.lightgrey),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 7),
            ]
        )
    )
    total = len(snapshot["records"])
    labels = [attendance_label(r["status"]) for r in snapshot["records"]]
    counts = {
        k: labels.count(k)
        for k in ("Present", "Absent", "Present (draft)", "Absent (draft)")
        if k in ("Present", "Absent") or k in labels
    }
    content = [
        title,
        Paragraph(
            escape(
                " · ".join(
                    str(value)
                    for value in (
                        snapshot.get("institute_name"),
                        snapshot.get("course_code"),
                        snapshot.get("course_title"),
                        snapshot.get("term_code"),
                    )
                    if value
                )
            ),
            styles["Normal"],
        ),
        Paragraph(
            escape(
                " · ".join(
                    str(value)
                    for value in (
                        snapshot.get("branch"),
                        "Semester " + str(snapshot["semester"]) if snapshot.get("semester") else None,
                        "Section " + str(snapshot["section"]) if snapshot.get("section") else None,
                        snapshot.get("room"),
                        snapshot.get("timezone"),
                    )
                    if value
                )
            ),
            styles["Normal"],
        ),
        Paragraph(escape(meta), styles["Normal"]),
        Spacer(1, 8),
        Paragraph(
            escape(
                f"Start: {local_start(snapshot['starts_at'])} | Students: {total} | "
                + " · ".join(f"{k}: {v}" for k, v in counts.items())
            ),
            styles["Normal"],
        ),
        Spacer(1, 12),
        grid,
    ]

    def footer(canvas, doc):
        canvas.setFont("Helvetica", 8)
        canvas.drawString(36, 22, f"FaceTrack · page {doc.page} · {total} students")

    SimpleDocTemplate(
        output,
        pagesize=A4,
        leftMargin=36,
        rightMargin=36,
        topMargin=32,
        bottomMargin=36,
        invariant=1,
    ).build(content, onFirstPage=footer, onLaterPages=footer)
    if max(len(csv_bytes), len(output.getvalue())) > MAX_FILE_BYTES:
        raise ValueError("Report exceeds bounded worker result size.")
    return {
        "csv_base64": base64.b64encode(csv_bytes).decode(),
        "pdf_base64": base64.b64encode(output.getvalue()).decode(),
    }
