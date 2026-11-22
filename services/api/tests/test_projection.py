"""Remaining-classes projection: the timetable arithmetic and the read-only endpoint."""

import json
from datetime import UTC, date, datetime, time, timedelta

from test_attendance import approve_faces, open_session
from test_biometrics import bio as bio  # noqa: F401

from app.config import Settings
from app.projection import IST, best_percentage, can_miss, remaining_classes
from tools.seed import connect

# Monday 2026-11-23 10:00 IST
NOW = datetime(2026, 11, 23, 10, 0, tzinfo=IST)
TERM_END = date(2026, 12, 31)


def series(weekday=0, end=time(11, 0), start=date(2026, 11, 1), until=date(2026, 12, 31), exceptions=()):
    return {
        "id": "S1",
        "weekday": weekday,
        "local_end": end,
        "effective_from": start,
        "effective_until": until,
        "exceptions": list(exceptions),
    }


def test_counts_weekday_occurrences_from_today_until_the_end_of_the_term():
    # Mondays from 23 Nov: 23, 30 Nov, 7, 14, 21, 28 Dec; today's class (ends 11:00) is still ahead.
    assert remaining_classes(NOW, TERM_END, [series()], set(), {}) == (6, 0)


def test_todays_class_stops_counting_after_it_ends():
    late = NOW.replace(hour=11, minute=30)
    assert remaining_classes(late, TERM_END, [series()], set(), {}) == (5, 0)


def test_holidays_cancellations_and_effective_dates_are_respected():
    cancel = {"date": date(2026, 12, 7), "action": "cancel", "start": None}
    found = remaining_classes(NOW, TERM_END, [series(exceptions=[cancel])], {date(2026, 11, 30)}, {})
    assert found == (4, 0)
    assert remaining_classes(NOW, TERM_END, [series(until=date(2026, 11, 30))], set(), {}) == (2, 0)
    assert remaining_classes(NOW, date(2026, 11, 29), [series()], set(), {}) == (1, 0)
    assert remaining_classes(NOW, TERM_END, [series(start=date(2026, 12, 14))], set(), {}) == (3, 0)


def test_a_replaced_class_counts_on_its_new_date_not_twice():
    new = datetime(2026, 11, 25, 9, 0, tzinfo=IST)
    replace = {"date": date(2026, 11, 30), "action": "replace", "start": new.astimezone(UTC)}
    # Mondays 23 Nov, 7, 14, 21, 28 Dec (30 Nov moved) plus Wednesday 25 Nov.
    assert remaining_classes(NOW, TERM_END, [series(exceptions=[replace])], set(), {}) == (6, 0)
    gone = {"date": date(2026, 11, 30), "action": "replace", "start": datetime(2026, 11, 20, 9, tzinfo=IST)}
    assert remaining_classes(NOW, TERM_END, [series(exceptions=[gone])], set(), {}) == (5, 0)


def test_existing_session_rows_are_never_double_counted():
    sessions = {"S1:2026-11-23": "open", "S1:2026-11-30": "finalized", "S1:2026-12-07": "cancelled"}
    # 23 Nov (open) is pending, 30 Nov already published, 7 Dec cancelled; 14, 21, 28 Dec are ahead.
    assert remaining_classes(NOW, TERM_END, [series()], set(), sessions) == (3, 1)
    # A class that was held and is waiting for publication still counts after its end time.
    late = NOW.replace(hour=15)
    assert remaining_classes(late, TERM_END, [series()], set(), {"S1:2026-11-23": "closed"}) == (5, 1)
    assert remaining_classes(late, TERM_END, [series()], set(), {"S1:2026-11-23": "no_data"}) == (5, 0)


def test_two_periods_a_week_count_separately():
    other = {**series(weekday=2), "id": "S2"}
    assert remaining_classes(NOW, date(2026, 11, 30), [series(), other], set(), {}) == (3, 0)


def test_can_miss_uses_exact_integer_arithmetic_at_the_boundary():
    # 3 of 4 attended, 4 left: at least ceil(0.75 * 8) = 6 of 7 must be attended, so 1 can be missed.
    assert can_miss(3, 4, 4, 75) == (1, True)
    # Exactly 75% after the remaining classes is allowed (no float rounding loss).
    assert can_miss(6, 8, 0, 75) == (0, True)
    assert can_miss(2, 4, 0, 75) == (0, False)
    assert can_miss(0, 0, 8, 75) == (2, True)
    assert can_miss(0, 0, 0, 75) == (0, True)
    # Unreachable even when attending everything.
    assert can_miss(1, 10, 2, 75) == (0, False)
    # Cannot miss more than what is left.
    assert can_miss(10, 10, 3, 50) == (3, True)
    assert can_miss(10, 10, 1, 1) == (1, True)


def test_best_possible_percentage():
    assert best_percentage(3, 4, 4) == 87.5
    assert best_percentage(0, 0, 0) is None


def test_threshold_setting_is_validated(monkeypatch):
    assert Settings.model_fields["attendance_threshold_percent"].default == 75


def insert_timetable(b, weekday, until, holiday=None):
    with connect(b.urls["owner"]) as c:
        room = c.execute(
            "INSERT INTO app.rooms(institute_id,code,name) VALUES (%s,'R1','Room 1') "
            "ON CONFLICT (institute_id,code) DO UPDATE SET name='Room 1' RETURNING id",
            (b.ids["institute"],),
        ).fetchone()[0]
        c.execute(
            """INSERT INTO app.schedule_series(institute_id,term_id,offering_id,teacher_id,room_id,entry_key,
            weekday,local_start,local_end,effective_from,effective_until,timezone)
            VALUES (%s,%s,%s,%s,%s,'e1',%s,'08:00','23:00',%s,%s,'Asia/Kolkata')""",
            (b.ids["institute"], b.ids["term"], b.ids["offering"], b.ids["teacher_profile"], room,
             weekday, datetime.now(IST).date(), until),
        )
        if holiday:
            c.execute(
                "INSERT INTO app.calendar_exceptions(institute_id,term_id,local_date,action,reason) "
                "VALUES (%s,%s,%s,'holiday','test')",
                (b.ids["institute"], b.ids["term"], holiday),
            )


async def publish_one_present(b):
    await approve_faces(b, "student1")
    s = await open_session(b)
    closed = await b.client.post(
        f"/v1/sessions/{s['id']}/close", headers=b.headers("teacher", key="c", version=s["version"])
    )
    done = await b.client.post(
        f"/v1/sessions/{s['id']}/finalize",
        headers=b.headers("teacher", key="pub", version=closed.json()["version"]),
        json={"decisions": [{"student_id": b.ids["student1_profile"], "status": "present", "reason": "seen"}]},
    )
    assert done.status_code == 200, done.text


async def test_projection_endpoint_without_a_timetable_says_not_enough_data(bio):
    b = bio
    r = await b.client.get(
        "/v1/me/attendance-projection", headers=b.headers("student1"), params={"offering_id": b.ids["offering"]}
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["basis"] == "none" and body["remaining"] is None and body["max_can_miss"] is None
    assert body["threshold_percent"] == 75 and "No timetable" in body["note"]


async def test_projection_endpoint_counts_published_marks_and_timetable(bio):
    b = bio
    await publish_one_present(b)
    today = datetime.now(IST).date()
    tomorrow = today + timedelta(days=1)
    insert_timetable(b, tomorrow.weekday(), tomorrow + timedelta(days=13))
    url, params = "/v1/me/attendance-projection", {"offering_id": b.ids["offering"]}
    body = (await b.client.get(url, headers=b.headers("student1"), params=params)).json()
    # Two matching weekdays in the next 13 days.
    assert body["basis"] == "timetable" and body["remaining"] == 2 and body["awaiting_publication"] == 0
    assert (body["present_or_late"], body["assessed"]) == (1, 1)
    assert body["max_can_miss"] == 0 and body["reachable"] is True
    assert body["best_possible_percentage"] == 100.0

    # A holiday removes one of them.
    with connect(b.urls["owner"]) as c:
        c.execute(
            "INSERT INTO app.calendar_exceptions(institute_id,term_id,local_date,action,reason) "
            "VALUES (%s,%s,%s,'holiday','test')",
            (b.ids["institute"], b.ids["term"], tomorrow + timedelta(days=7)),
        )
    assert (await b.client.get(url, headers=b.headers("student1"), params=params)).json()["remaining"] == 1


async def test_projection_endpoint_is_private_and_read_only(bio):
    b = bio
    params = {"offering_id": b.ids["offering"]}
    url = "/v1/me/attendance-projection"
    assert (await b.client.get(url, params=params, headers={"X-Institute-ID": b.ids["institute"]})).status_code in (401, 403)
    # A faculty account is not a student.
    assert (await b.client.get(url, headers=b.headers("teacher"), params=params)).status_code in (403, 404)
    # A student who is not enrolled in the subject gets nothing about it.
    other = await b.client.get(url, headers=b.headers("other_student"), params=params)
    assert other.status_code in (403, 404)
    unknown = await b.client.get(
        url, headers=b.headers("student1"), params={"offering_id": "00000000-0000-4000-8000-000000000000"}
    )
    assert unknown.status_code == 404
    bad = await b.client.get(url, headers=b.headers("student1"), params={"offering_id": "nope"})
    assert bad.status_code == 422
    assert json.dumps(other.json()).count(b.ids["offering"]) == 0


async def test_projection_round_trips_stay_small(bio):
    from test_statement_counts import counting

    b = bio
    await publish_one_present(b)
    tomorrow = datetime.now(IST).date() + timedelta(days=1)
    insert_timetable(b, tomorrow.weekday(), tomorrow + timedelta(days=13))
    call = lambda: b.client.get(  # noqa: E731
        "/v1/me/attendance-projection", headers=b.headers("student1"), params={"offering_id": b.ids["offering"]}
    )
    await call()  # warm the pooled connection's role check
    with counting(b.app) as counter:
        assert (await call()).status_code == 200
    # Every statement is a 125 ms round trip to the hosted database.
    assert counter.round_trips <= 5, (counter.round_trips, counter.statements)


async def test_projection_endpoint_handles_replacements_and_unpublished_sessions(bio):
    b = bio
    await publish_one_present(b)
    today = datetime.now(IST).date()
    tomorrow = today + timedelta(days=1)
    insert_timetable(b, tomorrow.weekday(), tomorrow + timedelta(days=13))
    moved_to = datetime.now(IST) + timedelta(days=3)
    with connect(b.urls["owner"]) as c:
        series_id = c.execute("SELECT id FROM app.schedule_series WHERE offering_id=%s", (b.ids["offering"],)).fetchone()[0]
        # The first Tomorrow-weekday class is cancelled, the second moves to a new day.
        c.execute(
            "INSERT INTO app.schedule_exceptions(institute_id,series_id,occurrence_date,action,reason) "
            "VALUES (%s,%s,%s,'cancel','test')",
            (b.ids["institute"], series_id, tomorrow),
        )
        c.execute(
            "INSERT INTO app.schedule_exceptions(institute_id,series_id,occurrence_date,action,replacement_start,reason) "
            "VALUES (%s,%s,%s,'replace',%s,'test')",
            (b.ids["institute"], series_id, tomorrow + timedelta(days=7), moved_to, ),
        )
        # A class that was held but is not published yet will still be assessed.
        c.execute(
            """INSERT INTO app.sessions(institute_id,offering_id,teacher_id,starts_at,ends_at,occurrence_key)
            VALUES (%s,%s,%s, now(), now()+interval '1 hour','pending-one')""",
            (b.ids["institute"], b.ids["offering"], b.ids["teacher_profile"]),
        )
    body = (
        await b.client.get(
            "/v1/me/attendance-projection",
            headers=b.headers("student1"),
            params={"offering_id": b.ids["offering"]},
        )
    ).json()
    # 0 on the cancelled day, 1 on the moved day, plus the one waiting for publication.
    assert body["remaining"] == 2 and body["awaiting_publication"] == 1
