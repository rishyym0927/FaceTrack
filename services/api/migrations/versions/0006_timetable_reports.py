"""Versioned timetable imports and publication-based reporting/delivery jobs."""

from pathlib import Path
from alembic import op

revision = "0006_timetable_reports"
down_revision = "0005_attendance"


def upgrade():
    op.execute((Path(__file__).parents[1] / "timetable_reports_schema.sql").read_text())


def downgrade():
    raise RuntimeError("Use additive repair; preserve reports and schedules.")
