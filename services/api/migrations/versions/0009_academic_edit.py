"""Add restricted administrative academic metadata updates."""

from pathlib import Path

from alembic import op

revision = "0009_academic_edit"
down_revision = "0008_admin"


def upgrade():
    op.execute((Path(__file__).parents[1] / "academic_edit_schema.sql").read_text())


def downgrade():
    op.execute("DROP FUNCTION app.admin_edit_academic(text,uuid,integer,jsonb)")
