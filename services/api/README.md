# FaceTrack backend foundation

The architecture authority is the root `MASTER_DESIGN.md`. This file contains executable service setup. Approved identities, academic enrolment, consent/private biometric processing, sessions/recognition review, immutable publications, timetable import and reports are implemented in source. Schema head 0006 is applied to the development Supabase project. One real low-light classroom session was teacher-reviewed and published; final CSV/PDF downloads and own student history were user-confirmed. A one-row live timetable import created a scheduled session for its selected matching date. Broader recognition, recovery and email acceptance remain open. Do not reseed or recreate accounts for routine development.

## Local verification

The commands in this section are the verified macOS path. Windows users should run the API in its Linux container using the root [Windows guide](../../docs/WINDOWS_SETUP.md). The hosted Supabase configuration and security rules are identical on both platforms.

From the repository root, install the **separate backend environment**, preserving the frozen root ML lock/environment:

```sh
export UV_CACHE_DIR="$PWD/.cache/uv"
uv sync --project services/api --locked --python .tools/python/cpython-3.11.15-macos-aarch64-none/bin/python3.11
cd services/api
.venv/bin/python -m tools.local_db start
.venv/bin/python -m pytest tests -q
.venv/bin/ruff check app migrations tools tests
```

PostgreSQL 16 binaries (`initdb`, `pg_ctl`) must be on PATH. The managed cluster uses loopback port 55432 and a private Unix socket, with separate `facetrack_dev` and `facetrack_test` databases. It creates `services/api/.env` only when absent. Private state and credentials are under `.local/backend`; do not commit or print them. Stop only this cluster with `.venv/bin/python -m tools.local_db stop`.

Tests use actual PostgreSQL constraints, transactions and RLS, synthetic identities and locally signed ES256 tokens with an explicitly mocked Auth HTTP provider. The fixture truncates **only the managed test database**, guarded by database plus local Unix-socket/macOS or loopback-host/Windows assertions. It does not operate on hosted Supabase. A passing local suite does not establish live Supabase compatibility.

Start the API from `services/api`:

```sh
.venv/bin/uvicorn app.main:create_app --factory --host 127.0.0.1 --port 8000
```

Interactive contract: `http://127.0.0.1:8000/docs`. Liveness is `/health/live`; readiness is `/health/ready`. Readiness checks the restricted database role, migration head 0007, 37 RLS tables and Auth configuration; it does not replace a real login check. The configured hosted development project reached 0007 on 26 October. There is no development login bypass.

## Connect the new free Supabase development project

Use an empty **development** project and controlled demo accounts. Do not paste passwords, tokens or secret keys into chat. Edit `services/api/.env` locally using `.env.example` as the field reference. Keep the generated join-code keyring; replacing it makes existing codes unrecoverable. Keep `.env` permissions at 0600. Do not copy the migration owner credential into the runtime field.

1. Set `SUPABASE_URL` to the project's HTTPS origin and `SUPABASE_PUBLISHABLE_KEY` to its publishable project key. You can save that key with `.venv/bin/python -m tools.configure_auth`, which prompts without echoing it. Check Auth signing keys: this API supports **ES256/P-256** user tokens. Legacy HS256 and other signing algorithms deliberately fail verification; explicitly configure the development project rather than weakening validation.
2. For a session-pooler URI, run `.venv/bin/python -m tools.configure_supabase 'COPIED_URI_WITH_[YOUR-PASSWORD]_PLACEHOLDER'`. It prompts for the database password with hidden input, encodes it and updates only the private operator URL/project origin. It does not connect, migrate or change the runtime role. Alternatively, set `MIGRATION_DATABASE_URL` using the owner's PostgreSQL connection string, prefixed `postgresql+psycopg://`, with `sslmode=require`. URL-encode reserved password characters. Use a direct connection if reachable, otherwise the shared **session-mode** pooler on port 5432. Do not use transaction-mode pooling for these tools.
3. Run `.venv/bin/python -m tools.provision_role`. It creates `facetrack_api` as a non-owner login without elevated role attributes or role memberships. Its generated password is stored only in `.local/backend/hosted-runtime-password`. Existing roles/credentials are not silently replaced.
4. Set `DATABASE_URL` to the same database using the restricted role and its generated password. For a shared session pooler the username is `facetrack_api.PROJECT_REF`; for direct connections it is `facetrack_api`. The owner pooler username is normally `postgres.PROJECT_REF`. Use the host shown by your project's Connect panel. Keep the database name from that panel.
5. Run `.venv/bin/alembic upgrade head`. Migrations require an owner with RLS bypass (the development project's `postgres` owner), separate from the runtime role. They create only the private `app` business schema. Keep `app` out of exposed Data API schemas. They remove client-role grants; client apps access business records through FastAPI.
6. Create six controlled, confirmed email/password Auth accounts through the development dashboard: `teacher`, `unassigned`, `other_teacher`, `student1`, `student2`, `other_student`. These are labels for test accounts, not required email addresses. Public signup/SMTP setup is deferred; do not disable confirmation for real student signup.

Create `.local/backend/demo-users.json` at the repository root, mode 0600, using actual dashboard Auth IDs and confirmed emails:

```json
{
  "teacher": {"id": "ACTUAL_AUTH_UUID", "email": "ACTUAL_CONFIRMED_EMAIL"},
  "unassigned": {"id": "ACTUAL_AUTH_UUID", "email": "ACTUAL_CONFIRMED_EMAIL"},
  "other_teacher": {"id": "ACTUAL_AUTH_UUID", "email": "ACTUAL_CONFIRMED_EMAIL"},
  "student1": {"id": "ACTUAL_AUTH_UUID", "email": "ACTUAL_CONFIRMED_EMAIL"},
  "student2": {"id": "ACTUAL_AUTH_UUID", "email": "ACTUAL_CONFIRMED_EMAIL"},
  "other_student": {"id": "ACTUAL_AUTH_UUID", "email": "ACTUAL_CONFIRMED_EMAIL"}
}
```

Do not store passwords in that file. From `services/api`:

```sh
.venv/bin/python -m tools.seed --users-file ../../.local/backend/demo-users.json --out ../../.local/backend/demo-ids.json
```

This inserts two synthetic institutes for isolation checks, approved faculty/student profiles, teacher memberships, terms, courses, groups and faculty assignments. Students remain unlinked until they claim their approved enrolment numbers (`0001`, `0002`, `0003`). Re-running does not reset approvals, suspensions or existing links; changed seed identity mappings fail instead of relinking people.

Restart the API to load the updated `.env`. With it running, use another terminal in `services/api`:

```sh
.venv/bin/python -m tools.smoke_supabase --users-file ../../.local/backend/demo-users.json --ids-file ../../.local/backend/demo-ids.json --out ../../.local/backend/hosted-smoke.json
```

The smoke check prompts privately for four controlled account passwords, obtains real hosted sessions, and tests verified-email linkage, code requests, teacher approval and denied student/unassigned/cross-tenant access. Tokens stay in memory. It rotates the demo offering's code and approves the controlled student; this is an intentional write test on seeded development data. The output contains only named checks, not tokens, passwords or participant results. **Verified on 23 October 2026:** the saved private smoke report passes all five check groups against real hosted Auth/database and the local API. This verifies the exercised foundation flow, not production readiness.

## API usage rules

- Bearer user token for `/v1/*`; `X-Institute-ID` for institute-scoped routes. `/v1/me` discovers only the caller's own links and memberships.
- Mutating POSTs require a fresh `Idempotency-Key` per logical action. Retry with the same body/key after a network failure. Changed body/version with the same key returns 409; completed effects persist atomically.
- Rotation uses the **offering's** `version` in `If-Match`. Approval uses the **enrolment's** version. Refresh after 409. Responses from current-code retrieval carry the code row's version; fetch the offering before rotation.
- Teacher creates an offering from faculty-only academic lookups. Self-assignment is the default; only an admin may select a different approved linked faculty profile.
- Student claims approved identity using `{"enrollment_number":"0001"}`, then submits `{"join_code":"XXXX-XXXX-XXXX"}` to `/v1/enrollment-requests`. Never send a student ID or a desired role. A request stays `requested` until review.
- Teacher reads `/v1/offerings/{id}/roster`, then PATCHes `/v1/offerings/{id}/enrollments/{enrollment_id}` with `{"status":"active","reason":"Verified class membership"}` and both concurrency headers.
- Students cannot read rosters or browse an institute catalogue. They see summaries only for their requested/approved offerings. A pending request does not make them attendance-eligible.
- Lists use `limit` (1–200, default 50) and `cursor` from `next_cursor`. Errors have `error.code/message/request_id/retryable/details` and omit submitted sensitive values.
- Ten fresh join-code lookups per user/institute per ten-minute window; invalid/expired lookups still consume quota. Same-key successful replays do not create more requests. Rejected/withdrawn enrolments require faculty action.

The generated current contract is `contracts/openapi.json` at the root. Regenerate after API changes with `.venv/bin/python -m tools.export_openapi`. Future API routes are specified in the master design, not implemented by this contract yet.

## Operations and remaining gates

The runtime grants no DELETE on academic records and no UPDATE/DELETE on audit events. Identity changes and faculty provisioning remain owner operations until an administration workflow is built. Expired code/idempotency state is ignored on read; automated expiry-row compaction and broader gateway abuse limits are follow-ups before an always-on release. Hosted role/grant checks and real provider smoke tests have passed for the development project. Backups/restore, cloud API deployment and load/recovery tests remain separate gates. No production-readiness claim follows from local tests.

Primary service references: [Supabase signing keys](https://supabase.com/docs/guides/auth/signing-keys), [custom roles](https://supabase.com/docs/guides/database/postgres/roles), [database connections](https://supabase.com/docs/guides/database/connecting-to-postgres), [RLS](https://supabase.com/docs/guides/database/postgres/row-level-security).

## Phase 3A read contracts (implemented)

`GET /v1/me/enrollments` returns institute-scoped own enrolment history (including rejected/withdrawn) with labelled offering summaries. Offering reads include course/term/branch/semester/section labels. Teacher roster accepts an optional status filter before pagination. Existing tenant/object permissions remain intact; no schema migration is required. `contracts/openapi.json` is regenerated and 21 PostgreSQL-backed tests pass. CORS permits only product web origins http://localhost:5300 and http://localhost:5301; the independent local-only camera spike needs no API access.

## Milestone 3B private enrolment

Current schema head is `0007_attendance_queries`: 37 business tables with forced tenant RLS. Additive migrations 0003/0004 implement consent, pinned models/profiles, private media, attempts, encrypted templates, jobs and scoped workers; 0005 adds attendance, 0006 timetable/reports, and 0007 evidence-coded attendance proposals plus student attendance queries. Never edit an applied migration. The API remains local; all business data stays in the private `app` schema.

Run from `services/api` after the existing owner/runtime configuration:

```sh
.venv/bin/python -m tools.configure_biometrics
.venv/bin/alembic upgrade head
.venv/bin/python -m tools.provision_enrollment --help
```

The hidden configuration prompt accepts the server-only `sb_secret_…` Storage key and generates a separate template keyring. Keep `.env` private; never copy it to Flutter/worker. Provisioning verifies the approved local academic model/profile, creates the private 25MiB MP4/WebM bucket, and writes a 30-day institute worker credential plus loopback Redis configuration. It refuses to replace an existing worker environment. This project is already provisioned: do not rerun token provisioning on routine startup. See `services/worker/README.md` for startup.

Optional real-provider transport check (synthetic bytes only, no face inference):

```sh
.venv/bin/python -m tools.check_storage
```

This verifies signed TUS create/append, metadata, private signed read and anonymous denial; its disposable object is deleted in `finally`. It does not establish real enrolment acceptance. Local tests use synthetic Storage/vectors, distinct from hosted checks. The latest backend suite has 41 passing PostgreSQL-backed tests, including attendance/report/timetable ownership and retry checks; real classroom acceptance remains separate.

## Attendance, queries, timetable and reports

The hosted development project and repository are at migration 0007. The private `facetrack-documents-dev` bucket (CSV/PDF, 25 MiB limit) and the **same** scoped worker token cover enrolment, recognition, timetable, report and optional delivery jobs. `tools.provision_documents` configures that bucket without replacing its credential; do not rerun account seeding or worker token provisioning. Restart the API, Celery and the agent after deployment.

Successful, sufficiently usable recognition may create `proposed_present` and `proposed_absent` draft rows. The latter is displayed as **Not recognized** and never becomes a final absence without teacher confirmation. Limited coverage, missing templates and processing failure remain `unassessed`. Students may query only their own latest published Absent result. Assigned teachers accept or reject the query with a reason; acceptance creates a new immutable publication and corrected report. Push/email query notifications and attachments are not implemented.

Teacher web → Classes → Sessions has manual sessions and a CSV import. First create any new room code in **Import timetable → Add room**. The template has exact columns `entry_key,term_code,course_code,branch,semester,section,teacher_email,room_code,weekday,start_time,end_time,effective_from,effective_until,timezone`; weekday values are MON–SUN and timezone is Asia/Kolkata. Upload → wait for validation → inspect preview → confirm a day within the term. Repeated confirmations are idempotent; conflicting room/faculty/class periods and stale previews fail safely. Opening/closing remains manual.

Closing a session queues a draft CSV/PDF; publication queues an immutable final revision. Teacher session details offer private 60-second report download grants and retry for failed generation. A synthetic multi-page ReportLab PDF was visually inspected; this does not establish a real faculty report. Optional Resend configuration uses `.venv/bin/python -m tools.configure_email`, entering the key privately and a verified permitted sender. No Resend account or sender is currently configured, so delivery stays disabled while downloads work. Do not paste the key into chat or frontend configuration.

Reservations last 15 minutes; provider upload tokens last two hours. Tombstones allow reconciliation of late writes until grant expiry. Teacher video grants last 60 seconds; already-issued capabilities can remain usable until expiry. Raw media is deleted at decision or the 24-hour deadline; withdrawal revokes activation/templates immediately and queues file deletion. The outbound agent runs cleanup on startup and periodically while the Mac is awake. Sleeping/offline infrastructure delays deletion: monitor backlog and reconcile before processing after restart.

A job is authoritative in PostgreSQL, not Redis. Worker endpoints use a hashed institute-scoped credential, model capabilities, 120-second leases, 15-second heartbeats and three total transient attempts. User JWTs cannot call them. Completion validates normalized 512D vectors and encrypts them in the API; no embeddings/keys are exposed in public responses or logs. Teacher approval rechecks consent/permissions/version under the student lock before replacing a compatible active set.

Provider references: [signed uploads](https://supabase.com/docs/reference/javascript/file-buckets-createsigneduploadurl), [resumable uploads](https://supabase.com/docs/guides/storage/uploads/resumable-uploads), [API keys](https://supabase.com/docs/guides/getting-started/api-keys). Signed resumable transport uses the direct Storage host and `/storage/v1/upload/resumable/sign`.
