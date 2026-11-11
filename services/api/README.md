# FaceTrack API

FastAPI verifies Supabase Auth tokens and manages tenant and object authorization, academic records, biometric enrolment, sessions, attendance publication and queries, timetables, private reports and durable job state. The architecture authority is [`MASTER_DESIGN.md`](../../MASTER_DESIGN.md); the canonical setup is [`docs/INSTALLATION.md`](../../docs/INSTALLATION.md).

## Current contract

- Python `>=3.11,<3.12`, FastAPI, Pydantic 2, SQLAlchemy Core/asyncio and psycopg 3
- PostgreSQL schema head `0008_admin`
- 37 business tables with forced RLS
- restricted `facetrack_api` runtime role; separate owner credential for migrations/tools
- Supabase ES256 user-token verification; no development login bypass
- generated OpenAPI: [`contracts/openapi.json`](../../contracts/openapi.json)

Use the OpenAPI snapshot for exact methods, parameters and request bodies. It includes the
internal worker contract. Azure serves the public app API and blocks both the internal routes
and interactive API documentation.

| Workflow | Entry points |
| --- | --- |
| Health and account | `GET /health/live`, `GET /health/ready`, `GET /v1/me`, `POST /v1/identity/claim` |
| Subjects and enrolment | `GET /v1/offerings`, `/v1/offerings/{offering_id}/join-code`, `POST /v1/enrollment-requests`, `GET /v1/me/enrollments` |
| Face enrolment | `GET /v1/privacy/notice`, `/v1/consents`, `GET /v1/me/biometric-enrollment`, `/v1/biometric-enrollments` |
| Classroom capture and attendance | `/v1/sessions`, `/v1/sessions/{identifier}/captures`, `/v1/captures/{identifier}`, `GET /v1/me/attendance` |
| Attendance summaries and disputes | `GET /v1/offerings/{offering_id}/attendance-summary`, `GET /v1/me/attendance-disputes`, `POST /v1/attendance-disputes/{identifier}/resolve` |
| Timetables and reports | `/v1/rooms`, `/v1/media-reservations`, `/v1/timetable-imports`, `GET /v1/sessions/{identifier}/reports`, `GET /v1/reports/{identifier}/download` |
| Institute administration | `/v1/admin/*` for terms, subjects, class groups, allocations, faculty, students, memberships and assignments |
| Processing | `/internal/v1/*` for scoped worker leases, inputs, results and reconciliation |

## Native development

From the repository root:

```sh
uv sync --project services/api --locked --python 3.11
cd services/api
.venv/bin/python -m tools.local_db start
.venv/bin/python -m pytest tests -q
.venv/bin/ruff check app migrations tools tests
```

The test suite uses the guarded local `facetrack_test` database, mocked Auth/Storage and synthetic identities. Hosted acceptance uses a separate smoke command. PostgreSQL 16 `initdb` and `pg_ctl` must be on PATH. Stop only the managed cluster with:

```sh
.venv/bin/python -m tools.local_db stop
```

After [configuring an environment](../../docs/INSTALLATION.md), start the API from `services/api`:

```sh
.venv/bin/uvicorn app.main:create_app --factory --host 127.0.0.1 --port 8000 --no-access-log
```

- OpenAPI UI: `http://127.0.0.1:8000/docs`
- Liveness: `http://127.0.0.1:8000/health/live`
- Readiness: `http://127.0.0.1:8000/health/ready`

Readiness checks the restricted runtime role, migration `0008_admin`, 37 forced-RLS tables and publishable-key configuration. It does not test a real Auth login, Storage or worker.

## Docker development

With a configured API environment, start the API from the repository root:

```sh
docker compose up -d --build --wait api
docker compose logs -f api
```

The canonical `compose.yaml` mounts this source directory and private `.local` state. Port 8000 binds to host loopback. See the installation guide to start Redis, the worker and the agent together.

## Configuration

Copy `.env.example` to `.env`; never commit `.env`. The example lists every application setting plus the operator-only migration URL. The field reference and secure first-time provisioning order are in [`docs/INSTALLATION.md`](../../docs/INSTALLATION.md#9-configuration-reference).

Key rules:

- `DATABASE_URL` must use the restricted `facetrack_api` role.
- `MIGRATION_DATABASE_URL` is owner-only and used by Alembic/seed/provision tools.
- `SUPABASE_STORAGE_SECRET`, template keys and database credentials never enter Flutter.
- `CORS_ORIGINS` must be exact HTTP(S) origins; non-loopback HTTP is rejected.
- Resend values are optional. Private CSV/PDF downloads work without email.

## Provisioning

Follow [first-time owner setup](../../docs/INSTALLATION.md#5-first-time-owner-setup-with-a-new-supabase-project)
for the ordered commands and expected results. For native development, run the same Python modules
and Alembic commands from `services/api` with this service's virtual environment.

Use an existing environment as-is for routine startup. Owner provisioning, migration, demo seeding
and worker credential changes are separate operator actions. The scoped worker credential expires
30 days after provisioning.

After [granting the first admin](../../docs/INSTALLATION.md#56-make-the-first-admin-and-set-up-the-institute),
authorized institute admins use the Teacher app's **Admin** tab. Creating login accounts there also
requires the optional server-only `SUPABASE_SERVICE_ROLE_KEY`.

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

## Request conventions

- Send a Supabase Auth user access token as `Authorization: Bearer …` on protected routes. The privacy notice and health endpoints are public.
- Send the active institute UUID in `X-Institute-ID` on institute-scoped routes. Permissions come from approved memberships and profiles. Join codes create pending requests.
- Follow the endpoint's OpenAPI header requirements. Idempotent writes accept `Idempotency-Key`. Versioned writes require `If-Match` with the current resource version. Retry a network failure with the same key and payload. On a version conflict, reload before submitting a new decision.
- For paginated lists, follow `next_cursor` with the same filters until it is null. Use a `limit` from 1 to 200 where supported. Treat cursor values as opaque.
- Errors return an `error` object with `code`, `message`, `request_id`, `retryable` and `details`. Use the request ID to correlate sanitized logs.

For example, with an authorized test user's access token and institute UUID loaded into the shell:

```sh
curl --fail-with-body --silent --show-error \
  --header "Authorization: Bearer ${FACETRACK_ACCESS_TOKEN}" \
  --header "X-Institute-ID: ${FACETRACK_INSTITUTE_ID}" \
  "http://127.0.0.1:8000/v1/me/attendance?limit=20"
```

### Attendance and timetable workflows

1. The teacher opens a session and the API freezes the approved roster. Each classroom segment uses a capture reservation, upload grant and upload completion call. Processing updates drafts asynchronously.
2. After usable capture, corroborated matches start as **Present** and remaining roster members as **Absent**. With no usable capture, the teacher marks the roster manually. Draft decisions can be changed before publication.
3. The teacher closes the session, waits for pending processing and submits `POST /v1/sessions/{identifier}/finalize`. The API requires **Present** or **Absent** for each roster member and creates an immutable revision. Student history reads the latest revision for each session and uses stable ordering across corrections.
4. Corrections and accepted disputes create a new revision. A legacy revision with marks that cannot carry forward to a binary publication yields `409 REVIEW_REQUIRED` and preserves the existing revision.

For timetables, reserve a private CSV upload, submit `POST /v1/timetable-imports`, review the parsed result
and commit with `POST /v1/timetable-imports/{identifier}/commit`. Creating the import rechecks faculty
access and reservation ownership and purpose after Storage validation.

## Storage and retention

- `facetrack-enrollment-dev`: private MP4/WebM, maximum 25 MiB
- `facetrack-documents-dev`: private CSV/PDF, maximum 25 MiB
- application upload reservations: 15 minutes
- review/report grants: short-lived and object-scoped
- raw media: eligible for cleanup after decision or processing, with a 24-hour retention target

Cleanup/reconciliation runs through the worker agent while the host is awake. Offline time can delay cleanup, so check the backlog after restart.

## Contract maintenance

After any route/schema change:

```sh
.venv/bin/python -m tools.export_openapi
.venv/bin/python -m pytest tests -q
.venv/bin/ruff check app migrations tools tests
```

Never edit an applied migration. Add a new migration, keep backward-compatible clients during rollout, and update the master design only when the contract/architecture changes.
