"""Permit only scoped worker job audit append; never grant audit updates/deletes."""

from alembic import op

revision = "0004_worker_audit"
down_revision = "0003_biometrics"


def upgrade():
    op.execute("""CREATE POLICY worker_job_audit ON app.audit_events FOR INSERT WITH CHECK (
        institute_id=app.tenant_id() AND app.is_worker() AND actor_id IS NULL
        AND action IN ('job.processed','job.failed') AND resource_type='job'
        AND EXISTS (SELECT 1 FROM app.worker_identities w JOIN app.jobs j
          ON j.institute_id=w.institute_id AND j.lease_owner=w.id
          WHERE w.token_hash=current_setting('app.worker_token_hash',true)
          AND w.institute_id=audit_events.institute_id AND j.id=audit_events.resource_id
          AND summary->>'worker_id'=w.id::text))""")


def downgrade():
    op.execute("DROP POLICY worker_job_audit ON app.audit_events")
