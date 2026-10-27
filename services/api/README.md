# FaceTrack API

FastAPI owns authentication, tenant/object authorization, academic records, biometric lifecycle, sessions, attendance publication/queries, timetable imports, private reports and durable job state. The architecture authority is [`MASTER_DESIGN.md`](../../MASTER_DESIGN.md); the canonical setup is [`docs/INSTALLATION.md`](../../docs/INSTALLATION.md).

## Current contract

- Python `>=3.11,<3.12`, FastAPI, Pydantic 2, SQLAlchemy Core/asyncio and psycopg 3
- PostgreSQL schema head `0008_admin`
- 37 business tables with forced RLS
- restricted `facetrack_api` runtime role; separate owner credential for migrations/tools
- Supabase ES256 user-token verification; no development login bypass
- generated OpenAPI: [`contracts/openapi.json`](../../contracts/openapi.json)

Implemented route groups:

- `/health/*`
- `/v1/me`, identity claim, academics, offerings, join codes, enrolment requests/rosters
- consent, biometric enrolment, upload/review and job status
- sessions, frozen roster, classroom captures, attendance review/publication/corrections/history
- student attendance disputes and teacher resolution
- rooms, timetable import/schedule and private report/download/delivery
- per-subject attendance summary (`/v1/offerings/{id}/attendance-summary`) used by the faculty and admin dashboards
- admin provisioning `/v1/admin/*`: terms, subjects, sections, allocations, faculty, students, memberships and assignments (every write re-checked by an `app.admin_*` database function)
- scoped `/internal/v1/*` worker lease/input/result/reconciliation endpoints

## Native development

From the repository root:

```sh
uv sync --project services/api --locked --python 3.11
cd services/api
.venv/bin/python -m tools.local_db start
.venv/bin/python -m pytest tests -q
.venv/bin/ruff check app migrations tools tests
```

The test suite uses only the guarded local `facetrack_test` database, mocked Auth/Storage and synthetic identities. It never calls live Supabase. PostgreSQL 16 `initdb` and `pg_ctl` must be on PATH. Stop only the managed cluster with:

```sh
.venv/bin/python -m tools.local_db stop
```

Start the API:

```sh
.venv/bin/uvicorn app.main:create_app --factory --host 127.0.0.1 --port 8000 --no-access-log
```

- OpenAPI UI: `http://127.0.0.1:8000/docs`
- Liveness: `http://127.0.0.1:8000/health/live`
- Readiness: `http://127.0.0.1:8000/health/ready`

Readiness checks the restricted runtime role, migration `0008_admin`, 37 forced-RLS tables and publishable-key configuration. It does not test a real Auth login, Storage or worker.

## Docker development

From the repository root:

```sh
docker compose build api
docker compose up -d api
docker compose logs -f api
```

The canonical `compose.yaml` mounts this source directory and private `.local` state. Only port 8000 binds to host loopback.

## Configuration

Copy `.env.example` to `.env`; never commit `.env`. The example lists every application setting plus the operator-only migration URL. The field reference and secure first-time provisioning order are in [`docs/INSTALLATION.md`](../../docs/INSTALLATION.md#9-configuration-reference).

Key rules:

- `DATABASE_URL` must use the restricted `facetrack_api` role.
- `MIGRATION_DATABASE_URL` is owner-only and used by Alembic/seed/provision tools.
- `SUPABASE_STORAGE_SECRET`, template keys and database credentials never enter Flutter.
- `CORS_ORIGINS` must be exact HTTP(S) origins; non-loopback HTTP is rejected.
- Resend values are optional. Private CSV/PDF downloads work without email.

## New project provisioning commands

Run these only for an empty development project and in the order documented in the installation guide:

```text
python -m tools.configure_supabase SESSION_POOLER_URI_WITH_[YOUR-PASSWORD]
python -m tools.configure_auth
python -m tools.provision_role
alembic upgrade head
python -m tools.seed --users-file DEMO_USERS_JSON --out DEMO_IDS_JSON
python -m tools.configure_biometrics
python -m tools.provision_enrollment
python -m tools.provision_documents
```

The configuration commands prompt for secrets without echoing them. `provision_enrollment` refuses to overwrite an existing worker environment. The scoped worker credential expires after 30 days; do not rotate it during normal startup.

For an already provisioned hosted project, do not reseed, rerun migrations or regenerate credentials merely to start the app.

The first admin is granted once by the operator with one SQL statement (see [installation §5.6](../../docs/INSTALLATION.md#56-make-the-first-admin-and-set-up-the-institute)); after that, admins manage everything from the Teacher app's **Admin** tab. Creating login accounts from that tab needs the optional, server-only `SUPABASE_SERVICE_ROLE_KEY`.

## Controlled demo seed

Create six confirmed Supabase Auth users and save their UUID/email pairs in ignored `.local/backend/demo-users.json`:

```json
{
  "teacher": {"id": "AUTH_UUID", "email": "CONTROLLED_EMAIL"},
  "unassigned": {"id": "AUTH_UUID", "email": "CONTROLLED_EMAIL"},
  "other_teacher": {"id": "AUTH_UUID", "email": "CONTROLLED_EMAIL"},
  "student1": {"id": "AUTH_UUID", "email": "CONTROLLED_EMAIL"},
  "student2": {"id": "AUTH_UUID", "email": "CONTROLLED_EMAIL"},
  "other_student": {"id": "AUTH_UUID", "email": "CONTROLLED_EMAIL"}
}
```

Do not store passwords in this file. The seed creates two synthetic institutes for isolation tests, approved profiles, memberships and academic records. Students link their approved identities using enrolment numbers `0001`, `0002` and `0003`. Re-running the seed is idempotent and does not reset workflow state.

The optional hosted smoke command obtains real sessions and intentionally exercises writes on seeded development data:

```sh
.venv/bin/python -m tools.smoke_supabase --users-file ../../.local/backend/demo-users.json --ids-file ../../.local/backend/demo-ids.json --out ../../.local/backend/hosted-smoke.json
```

Enter passwords only at its hidden prompts.

## API conventions

- `/v1/*` requires a Bearer user token.
- Institute-scoped routes require `X-Institute-ID`.
- Mutating requests use `Idempotency-Key`; optimistic writes also use `If-Match`.
- Retry a network failure with the same logical key/body. Refresh after a 409 version conflict.
- Lists use UUID cursors and `limit` 1–200.
- Errors use `error.code`, `message`, `request_id`, `retryable` and sanitized `details`.
- User roles come from approved memberships/profiles, never signup metadata or app selection.
- Join codes create pending requests, not attendance eligibility.
- Failed recognition never becomes absence. Teachers resolve proposals and publish.

## Storage and retention

- `facetrack-enrollment-dev`: private MP4/WebM, maximum 25 MiB
- `facetrack-documents-dev`: private CSV/PDF, maximum 25 MiB
- application upload reservations: 15 minutes
- review/report grants: short-lived and object-scoped
- raw media: delete after decision/processing and within the 24-hour target

Cleanup/reconciliation runs through the worker agent while the host is awake. Offline time can delay cleanup, so check the backlog after restart.

## Contract maintenance

After any route/schema change:

```sh
.venv/bin/python -m tools.export_openapi
.venv/bin/python -m pytest tests -q
.venv/bin/ruff check app migrations tools tests
```

Never edit an applied migration. Add a new migration, keep backward-compatible clients during rollout, and update the master design only when the contract/architecture changes.
