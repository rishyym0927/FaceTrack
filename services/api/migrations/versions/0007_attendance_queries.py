"""Teacher-confirmed absence proposals and immutable attendance queries."""

from pathlib import Path

from alembic import op

revision = "0007_attendance_queries"
down_revision = "0006_timetable_reports"


def upgrade():
    op.execute((Path(__file__).parents[1] / "attendance_queries_schema.sql").read_text())


def downgrade():
    raise RuntimeError("Use additive repair; preserve attendance publications and queries.")
