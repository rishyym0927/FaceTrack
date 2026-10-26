"""Administrative provisioning: is_admin predicate, admin write policies and functions."""

from pathlib import Path

from alembic import op

revision = "0008_admin"
down_revision = "0007_attendance_queries"


def upgrade():
    op.execute((Path(__file__).parents[1] / "admin_schema.sql").read_text())


def downgrade():
    raise RuntimeError("Use additive repair; preserve administrative provisioning.")
