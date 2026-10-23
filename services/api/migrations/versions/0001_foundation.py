"""Foundation tables, tenant RLS and restricted runtime grants.

Runtime role must be provisioned before this migration. Auth schema belongs to Supabase.
"""
from alembic import op

from migrations.foundation_schema import metadata

revision = "0001_foundation"
down_revision = None


def upgrade():
    conn = op.get_bind()
    op.execute("CREATE SCHEMA app")
    metadata.create_all(conn, tables=[t for t in metadata.sorted_tables if t.schema == "app"])
    for statement in [
        "REVOKE ALL ON SCHEMA app FROM PUBLIC",
        "GRANT USAGE ON SCHEMA app TO facetrack_api",
        "CREATE FUNCTION app.actor_id() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('app.actor_id', true), '')::uuid $$",
        "CREATE FUNCTION app.tenant_id() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('app.institute_id', true), '')::uuid $$",
        "CREATE FUNCTION app.claim_email() RETURNS text LANGUAGE sql STABLE AS $$ SELECT coalesce(current_setting('app.claim_email', true), '') $$",
        """CREATE FUNCTION app.is_member() RETURNS boolean LANGUAGE sql STABLE SECURITY INVOKER
           SET search_path = pg_catalog, app AS $$ SELECT EXISTS(
           SELECT 1 FROM app.memberships WHERE institute_id=app.tenant_id()
             AND auth_user_id=app.actor_id() AND status='active') $$""",
    ]:
        op.execute(statement)
    for name in ("actor_id", "tenant_id", "claim_email", "is_member"):
        op.execute(f"REVOKE ALL ON FUNCTION app.{name}() FROM PUBLIC")
        op.execute(f"GRANT EXECUTE ON FUNCTION app.{name}() TO facetrack_api")
    scoped = "institute_id=app.tenant_id() AND app.is_member()"
    for t in metadata.sorted_tables:
        if t.schema != "app":
            continue
        name = t.name
        op.execute(f"ALTER TABLE app.{name} ENABLE ROW LEVEL SECURITY")
        op.execute(f"ALTER TABLE app.{name} FORCE ROW LEVEL SECURITY")
        op.execute(f"REVOKE ALL ON app.{name} FROM PUBLIC")
        op.execute(f"GRANT SELECT ON app.{name} TO facetrack_api")
        if name == "memberships":
            own = "auth_user_id=app.actor_id() AND (app.tenant_id() IS NULL OR institute_id=app.tenant_id())"
            op.execute(f"CREATE POLICY own_memberships ON app.memberships FOR SELECT USING ({own})")
            op.execute("""CREATE POLICY claim_membership ON app.memberships FOR INSERT WITH CHECK (
                institute_id=app.tenant_id() AND auth_user_id=app.actor_id() AND role='student'
                AND status='active' AND EXISTS (SELECT 1 FROM app.students s WHERE
                s.institute_id=memberships.institute_id AND s.auth_user_id=app.actor_id()
                AND s.official_email=app.claim_email() AND s.status='approved'))""")
            op.execute("GRANT INSERT ON app.memberships TO facetrack_api")
        elif name == "institutes":
            op.execute("""CREATE POLICY own_institutes ON app.institutes FOR SELECT USING (
                EXISTS (SELECT 1 FROM app.memberships m WHERE m.institute_id=institutes.id
                AND m.auth_user_id=app.actor_id()))""")
        elif name in {"students", "teachers"}:
            own = "auth_user_id=app.actor_id() AND (app.tenant_id() IS NULL OR institute_id=app.tenant_id())"
            claim = "institute_id=app.tenant_id() AND official_email=app.claim_email() AND status='approved' AND (auth_user_id IS NULL OR auth_user_id=app.actor_id())"
            predicate = f"({scoped}) OR ({own})" + (f" OR ({claim})" if name == "students" else "")
            op.execute(f"CREATE POLICY profiles_read ON app.{name} FOR SELECT USING ({predicate})")
            if name == "students":
                op.execute(f"CREATE POLICY student_claim ON app.students FOR UPDATE USING ({claim}) WITH CHECK ({claim} AND auth_user_id=app.actor_id())")
                op.execute("GRANT UPDATE(auth_user_id, updated_at, version) ON app.students TO facetrack_api")
        else:
            policy = scoped
            if name in {"rate_limit_windows", "idempotency_records"}:
                policy += " AND actor_id=app.actor_id()"
            if name == "audit_events":
                # Audit is append-only for the runtime role.
                op.execute(f"CREATE POLICY scoped_read ON app.{name} FOR SELECT USING ({policy})")
                op.execute(f"CREATE POLICY scoped_append ON app.{name} FOR INSERT WITH CHECK ({policy} AND actor_id=app.actor_id())")
                op.execute(f"GRANT INSERT ON app.{name} TO facetrack_api")
            else:
                op.execute(f"CREATE POLICY scoped_rows ON app.{name} USING ({policy}) WITH CHECK ({policy})")
                if name not in {"terms", "courses", "class_groups"}:
                    op.execute(f"GRANT INSERT, UPDATE ON app.{name} TO facetrack_api")
    op.execute("CREATE INDEX assignment_teacher_idx ON app.offering_teachers(institute_id, teacher_id)")
    op.execute("CREATE INDEX enrollments_student_idx ON app.course_enrollments(institute_id, student_id, offering_id)")
    op.execute("CREATE INDEX idempotency_expiry_idx ON app.idempotency_records(expires_at)")
    op.execute("CREATE INDEX rate_limit_expiry_idx ON app.rate_limit_windows(window_start)")
    op.execute("GRANT SELECT ON public.alembic_version TO facetrack_api")
    op.execute("""CREATE FUNCTION app.check_active_teacher() RETURNS trigger
        LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,app AS $$
        BEGIN
          IF NEW.status='active' AND NOT EXISTS (
            SELECT 1 FROM app.teachers t JOIN app.memberships m
            ON m.institute_id=t.institute_id AND m.auth_user_id=t.auth_user_id
            WHERE t.institute_id=NEW.institute_id AND t.id=NEW.teacher_id
            AND t.status='approved' AND m.role='teacher' AND m.status='active') THEN
            RAISE EXCEPTION 'Faculty assignment is not active' USING ERRCODE='23514';
          END IF;
          RETURN NEW;
        END $$""")
    op.execute("REVOKE ALL ON FUNCTION app.check_active_teacher() FROM PUBLIC")
    op.execute("CREATE TRIGGER active_teacher BEFORE INSERT OR UPDATE ON app.offering_teachers FOR EACH ROW EXECUTE FUNCTION app.check_active_teacher()")


def downgrade():
    raise RuntimeError("Destructive foundation rollback is disabled; use an additive repair migration.")
