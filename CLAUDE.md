# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

FaceTrack is a human-reviewed, face-assisted attendance system: separate Student and Teacher Flutter apps, a FastAPI backend on hosted Supabase (Auth/PostgreSQL/private Storage), and a local Redis/Celery CPU worker running SCRFD + ArcFace-family ONNX models. Demo target: 28 October 2026.

`AGENTS.md` holds the binding project rules and `MASTER_DESIGN.md` the architecture authority. `PROGRESS.md` records actual verified state and `ROADMAP.md` the milestone gates. Read them before implementing. Do not create competing design documents. Check a roadmap item only after its outcome is verified, not because the code exists.

## Commands

Three independent Python environments, each with its own lock. Never add dependencies across them:

| Env | Location | Contents |
|---|---|---|
| Root | `.venv`, `uv.lock` | **Frozen** ML library `facetrack_ml` (receipt checked by `scripts/check_ml_freeze.py`) |
| API | `services/api/.venv` | FastAPI, SQLAlchemy Core, Alembic |
| Worker | `services/worker/.venv` | Celery, agent, reports; depends on root lib as editable |

```sh
# API (from services/api). Needs PostgreSQL 16 initdb/pg_ctl on PATH.
.venv/bin/python -m tools.local_db start        # guarded local `facetrack_test` cluster; `stop` to end
.venv/bin/python -m pytest tests -q
.venv/bin/python -m pytest tests/test_attendance.py::test_name -q   # single test
.venv/bin/ruff check app migrations tools tests
.venv/bin/uvicorn app.main:create_app --factory --host 127.0.0.1 --port 8000 --no-access-log
.venv/bin/python -m tools.export_openapi        # after ANY route/schema change; updates contracts/openapi.json

# Worker (from services/worker)
.venv/bin/python -m pytest tests -q

# Root ML/contract suite (from repo root; 1 expected failure documents a frozen-baseline limitation)
.venv/bin/python -m pytest tests -q
.venv/bin/python scripts/check_ml_freeze.py     # freeze receipt must stay unchanged

# Flutter: always use the wrapper (uses bundled .tools/ SDK, JDK 17, repo-local Gradle cache)
# Run inside each of packages/app_core, packages/capture, apps/student, apps/teacher
../../scripts/flutter analyze
../../scripts/flutter test
../../scripts/flutter test test/core_test.dart   # single file
# Web runs need public config (copy config/flutter.development.example.json to .local/flutter/development.json)
../../scripts/flutter run -d chrome --web-hostname localhost --web-port 5300 --dart-define-from-file=../../.local/flutter/development.json   # Teacher 5300, Student 5301, spike 5302

# Stack
docker compose up -d --build   # redis + api + worker + agent (also: make up|down|logs|health|console)
curl -fsS http://127.0.0.1:8000/health/ready
scripts/android-connect        # restore `adb reverse tcp:8000` after USB reconnect
```

From the repo root, API tests must be pointed at `services/api/tests` explicitly. Local API tests use managed PostgreSQL and mocked Auth/Storage, so they are not live Supabase acceptance. On Windows use `./run.ps1 <verb>` and `flutter` directly (see `docs/WINDOWS_SETUP.md`). Setup and the configuration reference are in `docs/INSTALLATION.md`.

## Architecture

**Processing flow (the part spanning many files):** The API is a modular monolith in `services/api/app/` (domain logic in `services.py`, `attendance.py`, `biometrics.py`, `documents.py`, with route installers like `biometric_routes.install` and `admin_routes.install` wired from `main.py`). PostgreSQL is the source of truth for jobs, leases and attendance. Redis only carries job and lease IDs, so losing it never loses state. The worker side is two processes in `services/worker/src/facetrack_worker/`:
- `agent.py` makes outbound-only HTTPS calls to the scoped `/internal/v1/*` API (`worker_api.py`) to claim, heartbeat (120 s lease, renewed every 15 s) and report results. It also runs storage cleanup and reconciliation.
- `executor.py` is the Celery task that validates media (origin, size, SHA-256, duration, no audio) and runs inference in an isolated child process via `inference.py` (enrolment, recognition, timetable and report adapters).
- The worker never holds DB credentials or the Storage secret. Only the API writes private Storage artifacts and commits results. Expired lease holders cannot commit. Effects must be idempotent.

**ML:** `services/worker/src/facetrack_ml/` is the **frozen** product pipeline (decode → quality → SCRFD → alignment → ArcFace 512D → exact NumPy roster-scoped cosine match → temporal corroboration). Do not alter its source, profile, templates or matching settings. `experiments/ml_accuracy/` is isolated research and must never be imported by production code. Model weights, profile and templates live in `.local/` (git-ignored).

**Attendance semantics:** See the [master design](MASTER_DESIGN.md#attendance) for draft defaults, publication and corrections.

**Database:** migration head `0008_admin`, 37 forced-RLS business tables (`/health/ready` checks both). Runtime uses restricted role `facetrack_api` (`DATABASE_URL`). The owner credential (`MIGRATION_DATABASE_URL`) is used only by Alembic and `tools/`. Never edit an applied migration; add a new one (SQL lives in `services/api/migrations/*.sql`, wrapped by `versions/`). Never expose the business schema through Supabase's Data API.

**API conventions:** `/v1/*` needs a Bearer token. Institute routes need `X-Institute-ID`. Mutations take `Idempotency-Key`, and optimistic writes take `If-Match`. Lists use UUID cursors (`limit` 1–200). Errors use an `error.code/message/request_id/retryable` envelope.

**Flutter:** Two separate apps (`apps/student`, `apps/teacher`) share `packages/app_core` (auth, API transport, go_router navigation, design system, `product_app.dart`), `packages/domain_models` and `packages/capture` (camera, pose guidance, pending media, resumable TUS upload). Platform splits use conditional-import `_io`/`_web`/`_stub` file triples. Each app keeps an isolated session store, and permissions are inferred from API memberships. `apps/teacher/lib/main_spike.dart` is the preserved camera spike, and `main_console.dart` is the model-test UI. `teacher_dashboard.dart` is the faculty home dashboard, computed in the app from `/v1/offerings` plus each subject's `attendance-summary`; `teacher_admin.dart` is the Admin tab (setup checklist, directories, role picker) over `/v1/admin/*`, shown only to active admins.

**Terminology:** visible text says Subject (offering), Section (class group), Semester term, Faculty (teacher). Identifiers, routes (`/classes`), JSON keys, the `teacher` role value and the timetable CSV columns keep the old names; change labels, not identifiers. Helpers `semesterLabel`, `termLabel` and `Offering.subtitle` live in `packages/domain_models`. Frontend config is public-only (API URL, Supabase URL/publishable key). Native cleartext is debug-only.

## Working rules specific to this repo

- Backend foundations may proceed although participant tests are held at 1/6; physical-device acceptance cannot be claimed from an APK build.
- Don't reinstall or restart the phone app while the user is recording. Don't regenerate worker credentials on routine startup. Don't reseed or rerun provisioning on the already-provisioned hosted project.
- Never accept consent or approve identity or poses on a user's behalf, and never publish attendance without human review.
- Never commit secrets, `.env`, recordings, embeddings, templates, ONNX files or participant-level results. Keep email delivery disabled (no Resend sender).
- Don't claim accuracy, latency, liveness or capacity targets without measurement. Use the [checkpoint](PROGRESS.md) for deployment and acceptance evidence.
- Update `PROGRESS.md` after meaningful milestones; record failures and checks not run.
