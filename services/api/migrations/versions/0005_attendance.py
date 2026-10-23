"""Sessions, immutable rosters, recognition evidence and publication revisions."""

from pathlib import Path

from alembic import op

revision = "0005_attendance"
down_revision = "0004_worker_audit"


def upgrade():
    op.execute((Path(__file__).parents[1] / "attendance_schema.sql").read_text())


def downgrade():
    raise RuntimeError("Use an additive repair; preserve attendance history.")
