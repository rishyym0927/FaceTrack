# Immutable schema snapshot for migration 0001; future changes use new migrations.
"""Foundation schema metadata. Policies/grants are versioned in the Alembic migration."""
import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import JSONB, UUID

metadata = sa.MetaData(schema="app")


def table(name, *columns, constraints=()):
    return sa.Table(name, metadata,
        sa.Column("id", UUID, primary_key=True, server_default=sa.text("gen_random_uuid()")),
        sa.Column("institute_id", UUID, nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False,
                  server_default=sa.text("now()")),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False,
                  server_default=sa.text("now()")),
        sa.Column("version", sa.Integer, nullable=False, server_default="1"),
        *columns, sa.UniqueConstraint("institute_id", "id"),
        sa.ForeignKeyConstraint(["institute_id"], ["app.institutes.id"]),
        sa.CheckConstraint("version > 0"), *constraints)


def col(name, kind=sa.Text, **kwargs):
    return sa.Column(name, kind, nullable=kwargs.pop("nullable", False), **kwargs)


def fk(parent, child="", *, extra=()):
    child = child or parent.removesuffix("s") + "_id"
    return sa.ForeignKeyConstraint(["institute_id", child, *extra],
                                   [f"app.{parent}.institute_id", f"app.{parent}.id",
                                    *[f"app.{parent}.{x}" for x in extra]])


institutes = sa.Table("institutes", metadata,
    col("id", UUID, primary_key=True, server_default=sa.text("gen_random_uuid()")),
    col("name"), col("timezone", server_default="Asia/Kolkata"),
    col("status", server_default="active"),
    col("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()")),
    col("updated_at", sa.DateTime(timezone=True), server_default=sa.text("now()")),
    sa.CheckConstraint("status IN ('active','suspended')"))

memberships = table("memberships", col("auth_user_id", UUID), col("role"),
    col("status", server_default="active"), constraints=(
        sa.ForeignKeyConstraint(["auth_user_id"], ["auth.users.id"], ondelete="CASCADE"),
        sa.UniqueConstraint("institute_id", "auth_user_id", "role"),
        sa.CheckConstraint("role IN ('student','teacher','admin')"),
        sa.CheckConstraint("status IN ('pending','active','suspended')")))

for name, number in [("students", "enrollment_number"), ("teachers", "employee_number")]:
    table(name, col("auth_user_id", UUID, nullable=True), col(number, sa.String(32)),
        col("official_name", sa.String(100)), col("official_email", sa.String(254)),
        col("status", server_default="approved"),
        *([col("template_epoch", sa.Integer, server_default="0")] if name == "students" else []),
        constraints=(
            sa.ForeignKeyConstraint(["auth_user_id"], ["auth.users.id"], ondelete="SET NULL"),
            sa.UniqueConstraint("institute_id", number),
            sa.UniqueConstraint("institute_id", "official_email"),
            sa.UniqueConstraint("institute_id", "auth_user_id"),
            sa.CheckConstraint("official_email = lower(trim(official_email))"),
            sa.CheckConstraint("status IN ('approved','suspended','archived')")))

terms = table("terms", col("code", sa.String(32)), col("starts_on", sa.Date),
    col("ends_on", sa.Date), col("schedule_revision", sa.Integer, server_default="0"),
    constraints=(sa.UniqueConstraint("institute_id", "code"),
                 sa.CheckConstraint("ends_on >= starts_on")))
courses = table("courses", col("code", sa.String(32)), col("title", sa.String(150)),
    col("status", server_default="active"), constraints=(
        sa.UniqueConstraint("institute_id", "code"),
        sa.CheckConstraint("status IN ('active','archived')")))
groups = table("class_groups", col("term_id", UUID), col("branch", sa.String(50)),
    col("semester", sa.Integer), col("section", sa.String(32)), constraints=(
        fk("terms", "term_id"), sa.UniqueConstraint("institute_id", "id", "term_id"),
        sa.UniqueConstraint("institute_id", "term_id", "branch", "semester", "section"),
        sa.CheckConstraint("semester BETWEEN 1 AND 20")))
offerings = table("offerings", col("term_id", UUID), col("course_id", UUID),
    col("class_group_id", UUID), col("title", sa.String(150)),
    col("status", server_default="active"), col("roster_version", sa.Integer, server_default="0"),
    constraints=(fk("terms", "term_id"), fk("courses", "course_id"),
        fk("class_groups", "class_group_id", extra=("term_id",)),
        sa.UniqueConstraint("institute_id", "class_group_id", "course_id"),
        sa.CheckConstraint("status IN ('active','archived')")))
assignments = table("offering_teachers", col("offering_id", UUID), col("teacher_id", UUID),
    col("can_finalize", sa.Boolean, server_default=sa.true()),
    col("status", server_default="active"), constraints=(
        fk("offerings", "offering_id"), fk("teachers", "teacher_id"),
        sa.UniqueConstraint("institute_id", "offering_id", "teacher_id"),
        sa.CheckConstraint("status IN ('active','inactive')")))
codes = table("offering_join_codes", col("offering_id", UUID), col("code_hash", sa.String(64)),
    col("ciphertext", sa.LargeBinary), col("nonce", sa.LargeBinary), col("key_id", sa.String(32)),
    col("expires_at", sa.DateTime(timezone=True)),
    col("revoked_at", sa.DateTime(timezone=True), nullable=True), constraints=(
        fk("offerings", "offering_id"), sa.UniqueConstraint("code_hash"),
        sa.UniqueConstraint("key_id", "nonce"), sa.CheckConstraint("octet_length(nonce) = 12")))
sa.Index("one_current_code_per_offering", codes.c.institute_id, codes.c.offering_id,
         unique=True, postgresql_where=codes.c.revoked_at.is_(None))
enrollments = table("course_enrollments", col("offering_id", UUID), col("student_id", UUID),
    col("status", server_default="requested"),
    col("effective_from", sa.DateTime(timezone=True), server_default=sa.text("now()")),
    col("effective_until", sa.DateTime(timezone=True), nullable=True),
    col("approved_by", UUID, nullable=True), col("reason", sa.String(500), nullable=True),
    constraints=(fk("offerings", "offering_id"), fk("students", "student_id"),
        sa.ForeignKeyConstraint(["approved_by"], ["auth.users.id"], ondelete="SET NULL"),
        sa.UniqueConstraint("institute_id", "offering_id", "student_id"),
        sa.CheckConstraint("status IN ('requested','active','rejected','withdrawn')"),
        sa.CheckConstraint("effective_until IS NULL OR effective_until >= effective_from")))
audit = table("audit_events", col("actor_id", UUID, nullable=True), col("action", sa.String(100)),
    col("resource_type", sa.String(100)), col("resource_id", UUID, nullable=True),
    col("request_id", sa.String(64)), col("summary", JSONB, server_default="{}"),
    constraints=(sa.ForeignKeyConstraint(["actor_id"], ["auth.users.id"], ondelete="SET NULL"),))
idempotency = table("idempotency_records", col("actor_id", UUID), col("route", sa.String(200)),
    col("key", sa.String(128)), col("request_hash", sa.String(64)),
    col("response_status", sa.Integer), col("response_json", JSONB),
    col("expires_at", sa.DateTime(timezone=True)), constraints=(
        sa.ForeignKeyConstraint(["actor_id"], ["auth.users.id"], ondelete="CASCADE"),
        sa.UniqueConstraint("institute_id", "actor_id", "route", "key")))
limits = table("rate_limit_windows", col("actor_id", UUID), col("action", sa.String(64)),
    col("window_start", sa.DateTime(timezone=True)), col("attempts", sa.Integer), constraints=(
        sa.ForeignKeyConstraint(["actor_id"], ["auth.users.id"], ondelete="CASCADE"),
        sa.UniqueConstraint("institute_id", "actor_id", "action", "window_start"),
        sa.CheckConstraint("attempts >= 0")))

# Auth is owned by Supabase, not by application migrations. This stub only resolves FK metadata.
auth_users = sa.Table("users", metadata, sa.Column("id", UUID, primary_key=True), schema="auth")
