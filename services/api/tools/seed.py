"""Approved synthetic academic data; hosted mode never creates Auth users."""

import argparse
import json
import os
from datetime import date, timedelta
from pathlib import Path
from uuid import NAMESPACE_URL, UUID, uuid5

import psycopg
from dotenv import load_dotenv
from psycopg import sql
from sqlalchemy import make_url


def uid(name):
    return uuid5(NAMESPACE_URL, "facetrack-foundation-demo:" + name)


def connect(url):
    parsed = make_url(url)
    return psycopg.connect(
        dbname=parsed.database,
        user=parsed.username,
        password=parsed.password,
        host=parsed.query.get("host", parsed.host),
        port=parsed.query.get("port", parsed.port),
        **({"sslmode": parsed.query["sslmode"]} if "sslmode" in parsed.query else {}),
    )


def seed(conn, users):
    """Idempotent inserts; never reset status, unlink accounts or overwrite real records."""
    ids = {
        name: uid(name)
        for name in [
            "institute",
            "other_institute",
            "term",
            "other_term",
            "course",
            "extra_course",
            "other_course",
            "group",
            "extra_group",
            "other_group",
            "offering",
            "other_offering",
            "teacher_profile",
            "unassigned_profile",
            "other_teacher_profile",
            "student1_profile",
            "student2_profile",
            "other_student_profile",
        ]
    }

    def insert(table, **values):
        columns = list(values)
        conn.execute(
            sql.SQL("INSERT INTO app.{} ({}) VALUES ({}) ON CONFLICT(id) DO NOTHING").format(
                sql.Identifier(table),
                sql.SQL(",").join(map(sql.Identifier, columns)),
                sql.SQL(",").join(sql.Placeholder() for _ in columns),
            ),
            list(values.values()),
        )

    expected = {"teacher", "unassigned", "other_teacher", "student1", "student2", "other_student"}
    if (
        set(users) != expected
        or len({u["id"] for u in users.values()}) != 6
        or len({u["email"].strip().lower() for u in users.values()}) != 6
    ):
        raise ValueError(
            "Supply exactly six distinct controlled demo accounts using the documented labels."
        )
    for name, user in users.items():
        auth = conn.execute(
            "SELECT email,email_confirmed_at FROM auth.users WHERE id=%s", (UUID(user["id"]),)
        ).fetchone()
        if not auth or auth[0].strip().lower() != user["email"].strip().lower() or not auth[1]:
            raise ValueError("Seed users must already exist with matching confirmed email.")
    today = date.today()
    for prefix, title in [("", "FaceTrack Demo"), ("other_", "Isolation Demo")]:
        inst = ids[prefix + "institute"]
        insert("institutes", id=inst, name=title)
        insert(
            "terms",
            id=ids[prefix + "term"],
            institute_id=inst,
            code="DEMO-TERM",
            starts_on=today - timedelta(days=30),
            ends_on=today + timedelta(days=90),
        )
        insert(
            "courses",
            id=ids[prefix + "course"],
            institute_id=inst,
            code="CS401",
            title="Data Structures",
        )
        insert(
            "class_groups",
            id=ids[prefix + "group"],
            institute_id=inst,
            term_id=ids[prefix + "term"],
            branch="CSE",
            semester=5,
            section="A",
        )
        insert(
            "offerings",
            id=ids[prefix + "offering"],
            institute_id=inst,
            term_id=ids[prefix + "term"],
            course_id=ids[prefix + "course"],
            class_group_id=ids[prefix + "group"],
            title="Data Structures",
        )
    insert(
        "courses",
        id=ids["extra_course"],
        institute_id=ids["institute"],
        code="CS402",
        title="Networks",
    )
    insert(
        "class_groups",
        id=ids["extra_group"],
        institute_id=ids["institute"],
        term_id=ids["term"],
        branch="ECE",
        semester=5,
        section="A",
    )
    for label, profile in [
        ("teacher", "teacher_profile"),
        ("unassigned", "unassigned_profile"),
        ("other_teacher", "other_teacher_profile"),
    ]:
        inst = ids["other_institute"] if label.startswith("other") else ids["institute"]
        existing = conn.execute(
            "SELECT auth_user_id,official_email FROM app.teachers WHERE id=%s", (ids[profile],)
        ).fetchone()
        if existing and (
            str(existing[0]) != users[label]["id"] or existing[1] != users[label]["email"].lower()
        ):
            raise ValueError("Existing faculty seed identity differs; refusing to relink it.")
        u = users[label]
        insert(
            "memberships",
            id=uid(label + "_membership"),
            institute_id=inst,
            auth_user_id=UUID(u["id"]),
            role="teacher",
        )
        insert(
            "teachers",
            id=ids[profile],
            institute_id=inst,
            auth_user_id=UUID(u["id"]),
            employee_number=label.upper(),
            official_name=label.replace("_", " ").title(),
            official_email=u["email"].lower(),
        )
    for label, profile, number in [
        ("student1", "student1_profile", "0001"),
        ("student2", "student2_profile", "0002"),
        ("other_student", "other_student_profile", "0003"),
    ]:
        inst = ids["other_institute"] if label.startswith("other") else ids["institute"]
        existing = conn.execute(
            "SELECT auth_user_id,official_email FROM app.students WHERE id=%s", (ids[profile],)
        ).fetchone()
        if existing and (
            existing[0] not in (None, UUID(users[label]["id"]))
            or existing[1] != users[label]["email"].lower()
        ):
            raise ValueError("Existing student seed identity differs; refusing to relink it.")
        insert(
            "students",
            id=ids[profile],
            institute_id=inst,
            enrollment_number=number,
            official_name=label.replace("_", " ").title(),
            official_email=users[label]["email"].lower(),
        )
    for offer, faculty, inst in [
        ("offering", "teacher_profile", "institute"),
        ("other_offering", "other_teacher_profile", "other_institute"),
    ]:
        insert(
            "offering_teachers",
            id=uid(offer + "_assignment"),
            institute_id=ids[inst],
            offering_id=ids[offer],
            teacher_id=ids[faculty],
        )
    return {name: str(value) for name, value in ids.items()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--users-file", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    load_dotenv(Path(__file__).parents[1] / ".env")
    users = json.loads(args.users_file.read_text())
    with connect(os.environ["MIGRATION_DATABASE_URL"]) as conn:
        ids = seed(conn, users)
    args.out.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    args.out.write_text(json.dumps(ids, indent=2))
    args.out.chmod(0o600)
    print("Approved demo records inserted; existing records preserved. IDs saved privately.")


if __name__ == "__main__":
    main()
