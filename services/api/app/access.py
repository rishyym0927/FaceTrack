"""Faculty access checks folded into the query that reads the protected row.

Every statement is a network round trip (about 125 ms to the hosted database), and the checks in
``security.teacher_access`` ran as three separate statements before the row was even read. The
checks here are identical, but ride along as scalar subqueries on the same statement, so they run
under the same row-level security with the same snapshot. Error precedence is unchanged: a missing
row is reported first, then a missing membership (403), then a missing assignment (404).
"""

from .db import one
from .errors import APIError
from .security import roles

# Active roles of the actor (:a) in the institute (:i).
ROLES = """(SELECT coalesce(array_agg(m.role),CAST('{}' AS text[])) FROM app.memberships m
    JOIN app.institutes inst ON inst.id=m.institute_id
    WHERE m.institute_id=:i AND m.auth_user_id=:a AND m.status='active'
    AND inst.status='active') AS _roles"""


def assigned(offering_expression: str) -> str:
    """Whether the actor (:a) is an approved faculty member actively assigned to the offering."""
    return f"""EXISTS(SELECT 1 FROM app.offering_teachers ot
    JOIN app.teachers t ON t.institute_id=ot.institute_id AND t.id=ot.teacher_id
    WHERE ot.institute_id=:i AND ot.offering_id={offering_expression} AND ot.status='active'
    AND t.auth_user_id=:a AND t.status='approved') AS _assigned"""


def decide(row):
    """Apply the faculty rules to a row carrying ``_roles`` and ``_assigned``; return it clean."""
    found = set(row["_roles"] or ())
    if not found:
        raise APIError(403, "MEMBERSHIP_REQUIRED", "Active institute membership is required.")
    if "admin" not in found and not ("teacher" in found and row["_assigned"]):
        raise APIError(404, "NOT_FOUND", "Offering not found.")
    return {k: v for k, v in row.items() if k not in ("_roles", "_assigned")}


async def teacher_access(conn, actor, institute, offering, *, lock=False):
    """The offering row, if the actor administers it or is assigned to it as faculty."""
    row = await one(
        conn,
        f"""SELECT o.*, {ROLES}, {assigned("o.id")} FROM app.offerings o
        WHERE o.institute_id=:i AND o.id=:o"""
        + (" FOR UPDATE OF o" if lock else ""),
        {"i": institute, "o": offering, "a": actor},
    )
    if not row:
        await roles(conn, actor, institute)  # no membership is a 403, whatever is missing
        raise APIError(404, "NOT_FOUND", "Offering not found.")
    return decide(row)
