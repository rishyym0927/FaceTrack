"""Exclude Supabase Data API roles even when owner default grants are configured."""
from alembic import op

revision = "0002_private_grants"
down_revision = "0001_foundation"


def upgrade():
    op.execute("""DO $$ DECLARE r text; BEGIN
      FOR r IN SELECT rolname FROM pg_roles WHERE rolname IN ('anon','authenticated','service_role') LOOP
        EXECUTE format('REVOKE ALL ON SCHEMA app FROM %I', r);
        EXECUTE format('REVOKE ALL ON ALL TABLES IN SCHEMA app FROM %I', r);
        EXECUTE format('REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM %I', r);
      END LOOP;
    END $$""")


def downgrade():
    raise RuntimeError("Do not restore broad default grants; use an additive repair migration.")
