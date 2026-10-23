"""Private biometric enrolment, durable jobs and scoped worker identities."""

from pathlib import Path

from alembic import op

revision = "0003_biometrics"
down_revision = "0002_private_grants"


def upgrade():
    op.execute((Path(__file__).parents[1] / "biometric_schema.sql").read_text())


def downgrade():
    raise RuntimeError("Biometric rollback requires an additive repair, never destructive removal.")
