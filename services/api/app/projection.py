"""Read-only projection of how many future classes a student can still miss.

Counts the classes still to come from the timetable and combines them with the student's
published attendance. Nothing is written. When the subject has no timetable the answer is
"not enough data" and never a guess.
"""

from datetime import date, datetime, time, timedelta
from typing import Annotated
from uuid import UUID
from zoneinfo import ZoneInfo

from fastapi import Depends, Header

from . import biometrics as bio
from .db import one, transaction
from .errors import APIError

IST = ZoneInfo("Asia/Kolkata")
# Sessions that exist and will still be assessed once they are published.
PENDING = ("scheduled", "open", "closed", "review_required")


def remaining_classes(now, term_end, series, holidays, sessions):
    """Classes still to be assessed.

    ``series``: dicts with id, weekday (0 = Monday), local_end, effective_from, effective_until and
    ``exceptions`` (date, action, start). ``holidays``: set of dates. ``sessions``: {occurrence_key:
    status}. Returns ``(timetable_ahead, awaiting_publication)``. Today's class counts only until
    its end time; a date that already has a session row is never counted twice.
    """
    today = now.date()
    ahead = 0
    for s in series:
        cancelled = {x["date"] for x in s["exceptions"] if x["action"] == "cancel"}
        replaced = {x["date"] for x in s["exceptions"] if x["action"] == "replace"}
        last = min(s["effective_until"], term_end)
        day = max(today, s["effective_from"])
        while day <= last:
            if day.weekday() == s["weekday"] and day not in holidays and day not in cancelled | replaced:
                key = f"{s['id']}:{day.isoformat()}"
                if key not in sessions and (day > today or s["local_end"] > now.time()):
                    ahead += 1
            day += timedelta(days=1)
        for x in s["exceptions"]:
            if x["action"] != "replace" or x["start"] is None:
                continue
            start = x["start"].astimezone(IST)
            if start.date() in holidays or f"{s['id']}:{x['date'].isoformat()}" in sessions:
                continue
            if start > now:
                ahead += 1
    waiting = sum(1 for status in sessions.values() if status in PENDING)
    return ahead, waiting


def can_miss(present, assessed, remaining, threshold):
    """Most of the remaining classes that can be missed while still ending at or above the threshold.

    Integer arithmetic, so a boundary like exactly 75% is never lost to rounding. Returns
    ``(max_can_miss, reachable)``; when the threshold cannot be reached any more the first value is 0.
    """
    needed = -(-threshold * (assessed + remaining) // 100)  # ceil without floats
    spare = present + remaining - needed
    if spare < 0:
        return 0, False
    return min(remaining, spare), True


def best_percentage(present, assessed, remaining):
    total = assessed + remaining
    return 100 * (present + remaining) / total if total else None


def install(app, engine, settings, principal):
    User = Annotated[object, Depends(principal)]
    Institute = Annotated[UUID, Header(alias="X-Institute-ID")]

    @app.get("/v1/me/attendance-projection")
    async def projection(offering_id: UUID, user: User, institute_id: Institute):
        threshold = settings.attendance_threshold_percent
        now = datetime.now(IST)
        async with transaction(engine, user.user_id, institute_id) as c:
            st = await bio.student(c, user.user_id, institute_id)
            # One statement: every extra statement is a 125 ms round trip to the hosted database.
            row = await one(
                c,
                """WITH marks AS (
                    SELECT mark->>'status' AS status
                    FROM app.session_roster r
                    JOIN app.sessions s ON s.institute_id=r.institute_id AND s.id=r.session_id
                    JOIN app.publications p ON p.institute_id=s.institute_id AND p.session_id=s.id
                        AND p.revision=s.attendance_revision
                    CROSS JOIN LATERAL jsonb_path_query_first(
                        p.snapshot_json, '$.records[*] ? (@.student_id == $student)'::jsonpath,
                        jsonb_build_object('student', CAST(r.student_id AS text))
                    ) AS mark
                    WHERE r.institute_id=:i AND r.student_id=:student AND s.offering_id=:o
                    AND mark IS NOT NULL
                )
                SELECT t.ends_on,
                    coalesce((SELECT array_agg(x.local_date) FROM app.calendar_exceptions x
                        WHERE x.institute_id=o.institute_id AND x.term_id=o.term_id
                        AND x.action='holiday'), '{}') AS holidays,
                    (SELECT count(*) FROM marks WHERE status IN ('present','late')) AS attended,
                    (SELECT count(*) FROM marks WHERE status IN ('present','late','absent')) AS assessed,
                    coalesce((SELECT jsonb_agg(jsonb_build_object(
                        'id', s.id, 'weekday', s.weekday, 'local_end', s.local_end,
                        'effective_from', s.effective_from, 'effective_until', s.effective_until,
                        'exceptions', coalesce((SELECT jsonb_agg(jsonb_build_object(
                            'date', x.occurrence_date, 'action', x.action, 'start', x.replacement_start))
                            FROM app.schedule_exceptions x
                            WHERE x.institute_id=s.institute_id AND x.series_id=s.id), '[]'::jsonb)))
                        FROM app.schedule_series s
                        WHERE s.institute_id=o.institute_id AND s.offering_id=o.id AND s.status='active'),
                        '[]'::jsonb) AS series,
                    coalesce((SELECT jsonb_object_agg(k.occurrence_key, k.status)
                        FROM app.sessions k
                        WHERE k.institute_id=o.institute_id AND k.offering_id=o.id
                        AND (k.starts_at >= :since OR k.status = ANY(:pending))),
                        '{}'::jsonb) AS known
                FROM app.course_enrollments e
                JOIN app.offerings o ON o.institute_id=e.institute_id AND o.id=e.offering_id
                JOIN app.terms t ON t.institute_id=o.institute_id AND t.id=o.term_id
                WHERE e.institute_id=:i AND e.offering_id=:o AND e.student_id=:student
                AND e.status='active'""",
                {
                    "i": institute_id,
                    "o": offering_id,
                    "student": st["id"],
                    "since": now - timedelta(days=2),
                    "pending": list(PENDING),
                },
            )
        if not row:
            raise APIError(404, "NOT_FOUND", "That subject was not found for you.")
        totals, offering, series = row, row, row["series"]
        present, assessed = totals["attended"], totals["assessed"]
        result = {
            "offering_id": str(offering_id),
            "present_or_late": present,
            "assessed": assessed,
            "threshold_percent": threshold,
            "policy_version": "session-v1",
        }
        if not series:
            return {
                **result,
                "basis": "none",
                "remaining": None,
                "awaiting_publication": None,
                "max_can_miss": None,
                "reachable": None,
                "best_possible_percentage": None,
                "note": "No timetable is loaded for this subject, so future classes cannot be counted.",
            }
        prepared = [
            {
                "id": s["id"],
                "weekday": s["weekday"],
                "local_end": time.fromisoformat(s["local_end"]),
                "effective_from": date.fromisoformat(s["effective_from"]),
                "effective_until": date.fromisoformat(s["effective_until"]),
                "exceptions": [
                    {
                        "date": date.fromisoformat(x["date"]),
                        "action": x["action"],
                        "start": datetime.fromisoformat(x["start"]) if x.get("start") else None,
                    }
                    for x in s["exceptions"]
                ],
            }
            for s in series
        ]
        ahead, waiting = remaining_classes(
            now,
            offering["ends_on"],
            prepared,
            set(offering["holidays"] or ()),
            dict(row["known"]),
        )
        remaining = ahead + waiting
        miss, reachable = can_miss(present, assessed, remaining, threshold)
        return {
            **result,
            "basis": "timetable",
            "remaining": remaining,
            "awaiting_publication": waiting,
            "max_can_miss": miss,
            "reachable": reachable,
            "best_possible_percentage": best_percentage(present, assessed, remaining),
            "note": "Counts timetable classes still to come and classes held but not yet published. "
            "Extra or rescheduled classes are not predicted.",
        }
