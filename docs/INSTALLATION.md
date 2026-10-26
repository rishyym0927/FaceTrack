# FaceTrack installation and setup

This is the canonical setup guide for the current repository. It describes the software that is actually implemented as of **26 October 2026**.

FaceTrack has three different run modes. Choose one before installing anything:

| Goal | Needs Supabase | Needs private model | Needs Flutter | Needs Docker |
|---|---:|---:|---:|---:|
| Run automated tests | No | No | Flutter tests only | No |
| Run the model-test console | No | Yes | Only to build the console page once | Yes for the packaged path |
| Run the complete Student/Teacher product | Yes | Yes | Yes | Yes on Windows/Linux; optional on the configured Mac |

The public Git repository intentionally excludes credentials, model weights, recordings, templates and demo passwords. A fresh clone can run the automated tests, but real face processing requires an approved model package and private configuration. The current InsightFace model permission covers only the confirmed non-commercial academic experiment; it does not automatically permit institute deployment.

## 1. What runs where

```text
Student web/Android ─┐
                     ├─ Supabase Auth
Teacher web/Android ─┘
          │
          └─ FastAPI :8000 ─ PostgreSQL (hosted Supabase)
                    │  └──── private Supabase Storage
                    └─ job agent ─ Redis ─ Celery worker
                                             ├─ SCRFD + ArcFace ONNX
                                             ├─ timetable CSV parsing
                                             └─ CSV/PDF reports
```

- Student web uses `http://localhost:5301`; Teacher web uses `http://localhost:5300`.
- FastAPI uses `http://127.0.0.1:8000` in development.
- Supabase Auth, PostgreSQL and private Storage are hosted and require internet access.
- Redis, Celery, the job agent and CPU inference run on the local computer.
- Android reaches the local API through `adb reverse tcp:8000 tcp:8000`.
- The API is one modular service. The worker is a separate process so video work does not block HTTP requests.

## 2. Supported hosts

| Host | Current status | Recommended path |
|---|---|---|
| macOS Apple Silicon | Verified demo host | Native services or the canonical Docker stack |
| Windows 10/11 x64 | Implemented; physical acceptance pending | Native Flutter + Docker Desktop Linux containers |
| Linux x64/ARM64 | Implemented; physical acceptance pending | Native Flutter + Docker Engine Linux containers |
| Android arm64 | Verified development client | USB debugging and port reverse to the host |

iOS and native Windows/macOS/Linux desktop applications do not exist. Windows and Linux use Flutter web in a browser. See [platform support](PLATFORM_SUPPORT.md) before promising a target.

## 3. Prerequisites

Install these before cloning the project:

1. **Git**.
2. **Docker with Compose v2.20 or newer**. Windows must use [Docker Desktop with the WSL 2 Linux engine](https://docs.docker.com/desktop/features/wsl/). Keep Docker in Linux-container mode.
3. **Flutter stable compatible with Dart 3.13.5**. The verified host uses Flutter 3.47.7. Follow Flutter's [web setup](https://docs.flutter.dev/platform-integration/web/setup); Chrome is the verified target and Edge is configured on Windows.
4. **Internet access** for Supabase and initial dependency/image downloads.
5. For Android builds: **JDK 17**, Android SDK/platform tools and a USB-debuggable Android phone.

For native Python development also install **Python 3.11**, [`uv`](https://docs.astral.sh/uv/getting-started/installation/) and FFmpeg/FFprobe. The Docker images already contain Python 3.11 and the worker image contains FFmpeg.

Verify the host:

```text
git --version
docker compose version
flutter --version
flutter doctor
flutter devices
```

The project requires Python `>=3.11,<3.12`; do not install its packages into a newer system Python.

### Locked dependency baseline

The lockfiles, not this table, are authoritative. The audited resolutions are:

| Area | Main locked versions |
|---|---|
| Root ML | NumPy 2.4.6, OpenCV headless 4.14.0.94, ONNX Runtime 1.31.0, cryptography 47.0.0, Pydantic 2.14.1, imageio-ffmpeg 0.6.0 |
| API | FastAPI 0.160.0, Uvicorn 0.54.0, SQLAlchemy 2.0.55, psycopg 3.3.6, Alembic 1.20.1, HTTPX 0.28.1 |
| Worker | Celery 5.6.3, Redis client 6.4.0, pandas 3.1.0, openpyxl 3.1.5, ReportLab 4.5.1 plus the root ML package |
| Flutter shared | supabase_flutter 2.18.3, Riverpod 3.4.3, go_router 17.5.0, Dio 5.11.1, secure storage 10.3.4 |
| Capture/apps | camera 0.12.1, ML Kit face detection 0.15.1, video_player 2.14.1, file_picker 13.1.0 |

Use `uv sync --locked` and `flutter pub get --enforce-lockfile`. Do not update packages as part of setup.

## 4. Fastest setup with an existing private package

Use this path for a teammate or client who received the prepared private configuration from the authorized operator.

### Windows PowerShell

```powershell
git clone https://github.com/rishyym0927/FaceTrack.git C:\FaceTrack
Set-Location C:\FaceTrack
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\windows\setup.ps1 -SkipContainerBuild
```

### macOS or Linux shell

```sh
git clone https://github.com/rishyym0927/FaceTrack.git
cd FaceTrack
scripts/setup.sh --skip-build
```

Extract the encrypted private package **into the repository root** so these paths exist:

```text
services/api/.env
services/worker/.env
.local/flutter/development.json
.local/spike/models/buffalo_sc/manifest.json
.local/spike/models/buffalo_sc/det_500m.onnx
.local/spike/models/buffalo_sc/w600k_mbf.onnx
.local/spike/profiles/frozen-phase1b-v1.json
```

Do not print these files. Check that Git ignores them:

```sh
git check-ignore services/api/.env services/worker/.env .local/flutter/development.json
```

Then start the backend:

```sh
# macOS/Linux
docker compose up -d --build
curl -fsS http://127.0.0.1:8000/health/ready
```

```powershell
# Windows
.\run.ps1 up
(Invoke-RestMethod http://127.0.0.1:8000/health/ready).status
```

The expected readiness response is `{"status":"ready"}`. Start the web apps in two terminals:

```sh
cd apps/teacher
../../scripts/flutter run -d chrome --web-hostname localhost --web-port 5300 --dart-define-from-file=../../.local/flutter/development.json
```

```sh
cd apps/student
../../scripts/flutter run -d chrome --web-hostname localhost --web-port 5301 --dart-define-from-file=../../.local/flutter/development.json
```

On Windows, the one-command equivalent is:

```powershell
.\scripts\windows\start-demo.ps1
```

Use `-Browser edge` if Chrome is unavailable. Enter demo passwords only in the apps. Public registration and password recovery are not configured.

Stop the stack with `docker compose down`, `make down`, `./run.ps1 down`, or `scripts\windows\stop-demo.ps1` as appropriate. Close the two Flutter terminals separately.

## 5. First-time owner setup with a new Supabase project

This path creates a new development environment. It requires access to a Supabase project and approved model artifacts. Do not run these steps against the shared demo unless you are its operator.

### 5.1 Create local configuration

Run the setup script from section 4 without a private package. It creates ignored templates when they are absent:

- `services/api/.env`
- `.local/flutter/development.json`

The script also installs the locked Flutter dependencies. Open these files in a local editor; do not paste their values into chat.

### 5.2 Create the Supabase development project

Create a free Supabase project. From its dashboard collect the [publishable/secret keys](https://supabase.com/docs/guides/getting-started/api-keys) and [database connection](https://supabase.com/docs/guides/database/connecting-to-postgres):

- project URL: `https://PROJECT_REF.supabase.co`
- publishable key: `sb_publishable_...`
- secret key: `sb_secret_...` (server only)
- **session-pooler** PostgreSQL URI on port `5432`, with username `postgres.PROJECT_REF`

In Supabase Auth signing-key settings, confirm the active user-token key is **ECC P-256 / ES256**. The API deliberately rejects HS256, anonymous sessions and other algorithms.

The secret key never enters Flutter. Use the session pooler when the host needs IPv4. Do not use transaction-mode port `6543` for migrations/provisioning.

Build the service images once:

```sh
docker compose build api worker
```

Save the owner connection and publishable key through hidden prompts:

```sh
docker compose run --rm api /opt/venv/bin/python -m tools.configure_supabase 'postgresql://postgres.PROJECT_REF:[YOUR-PASSWORD]@POOLER_HOST:5432/postgres'
docker compose run --rm api /opt/venv/bin/python -m tools.configure_auth
```

Keep the literal `[YOUR-PASSWORD]` placeholder in the first command; enter the real password only at the hidden prompt.

Provision the restricted runtime database role:

```sh
docker compose run --rm api /opt/venv/bin/python -m tools.provision_role
```

The generated password is stored in ignored `.local/backend/hosted-runtime-password`. In a local editor, set `DATABASE_URL` in `services/api/.env` to the same database using:

```text
postgresql+psycopg://facetrack_api.PROJECT_REF:RUNTIME_PASSWORD@POOLER_HOST:5432/postgres?sslmode=require
```

Keep `MIGRATION_DATABASE_URL` as the owner connection. Never reuse the owner account as `DATABASE_URL`.

Apply the schema:

```sh
docker compose run --rm api /opt/venv/bin/alembic upgrade head
```

Expected head: `0007_attendance_queries`, with 37 forced-RLS business tables.

### 5.3 Create controlled Auth accounts and seed demo academics

In Supabase Auth, create and confirm six controlled accounts for these roles:

```text
teacher, unassigned, other_teacher, student1, student2, other_student
```

They may use any controlled email addresses. Record only their Auth UUID and confirmed email in ignored `.local/backend/demo-users.json`, following the example in [the API guide](../services/api/README.md). Do not store passwords in that JSON.

Seed the development records:

```sh
docker compose run --rm api /opt/venv/bin/python -m tools.seed --users-file ../../.local/backend/demo-users.json --out ../../.local/backend/demo-ids.json
```

### 5.4 Configure private Storage and the worker

First place the approved manifest, ONNX files and frozen profile at the paths shown in section 4. See [the ML spike guide](ML_SPIKE.md) for provenance, hashes and permission checks.

Save the Supabase secret key and generate the template encryption keyring:

```sh
docker compose run --rm api /opt/venv/bin/python -m tools.configure_biometrics
```

Provision the private enrolment bucket, model/profile records, scoped worker token and Redis configuration:

```sh
docker compose run --rm api /opt/venv/bin/python -m tools.provision_enrollment
```

This command refuses to replace an existing `services/worker/.env`. Its worker credential expires after 30 days. Do not regenerate it during routine startup.

Provision the private report bucket and add timetable/report/delivery capabilities to the same worker:

```sh
docker compose run --rm api /opt/venv/bin/python -m tools.provision_documents
```

Report downloads work without email. Optional Resend delivery is configured later through `tools.configure_email` and requires a permitted sender.

### 5.5 Configure Flutter

Edit `.local/flutter/development.json`:

```json
{
  "API_BASE_URL": "http://127.0.0.1:8000",
  "SUPABASE_URL": "https://PROJECT_REF.supabase.co",
  "SUPABASE_PUBLISHABLE_KEY": "sb_publishable_REPLACE",
  "DEFAULT_INSTITUTE_ID": "UUID_FROM_demo-ids.json"
}
```

These four values are public application configuration. Never put the database password, Supabase secret key, worker token or template keys in this file.

Start the product using section 4. After the API is ready, run the hosted smoke check from a trusted operator machine as described in the API guide; it intentionally writes to seeded development data.

## 6. Native macOS developer path

The configured Mac can run services without Docker. Use six terminals from the repository root:

| Process | Directory | Command |
|---|---|---|
| Redis | root | `redis-server .local/enrollment/redis.conf` |
| API | `services/api` | `.venv/bin/uvicorn app.main:create_app --factory --host 127.0.0.1 --port 8000 --no-access-log` |
| Celery | `services/worker` | `.venv/bin/python -m celery -A facetrack_worker.executor:app worker --pool=solo --concurrency=1 --loglevel=WARNING --without-gossip --without-mingle` |
| Agent | `services/worker` | `.venv/bin/python -m facetrack_worker.agent` |
| Teacher | `apps/teacher` | `../../scripts/flutter run -d chrome --web-hostname localhost --web-port 5300 --dart-define-from-file=../../.local/flutter/development.json` |
| Student | `apps/student` | `../../scripts/flutter run -d chrome --web-hostname localhost --web-port 5301 --dart-define-from-file=../../.local/flutter/development.json` |

The native environments are separate: root ML, `services/api/.venv`, and `services/worker/.venv`. Do not merge their lockfiles or environments.

## 7. Android device

Enable Developer options and USB debugging, connect a data-capable cable, unlock the phone and accept its authorization prompt.

```sh
# macOS/Linux
scripts/android-connect
flutter devices
```

```powershell
# Windows
.\scripts\windows\android-connect.ps1
flutter devices
```

The helper restores `adb reverse tcp:8000 tcp:8000`. Keep the cable connected while the API is local. Do not reinstall or restart an app during an active recording.

Build debug APKs:

```sh
cd apps/student
../../scripts/flutter build apk --debug --target-platform android-arm64 --dart-define-from-file=../../.local/flutter/development.json
cd ../teacher
../../scripts/flutter build apk --debug --target-platform android-arm64 --dart-define-from-file=../../.local/flutter/development.json
```

Development Android permits loopback HTTP only in the debug manifest. Release builds require HTTPS and proper signing.

## 8. Tests that need no private data

### Python/ML

```sh
uv sync --locked --python 3.11
.venv/bin/python -m pytest tests -q

uv sync --project services/worker --locked --python 3.11
services/worker/.venv/bin/python -m pytest services/worker/tests -q
```

### API

Native API tests require local PostgreSQL 16 binaries:

```sh
uv sync --project services/api --locked --python 3.11
cd services/api
.venv/bin/python -m tools.local_db start
.venv/bin/python -m pytest tests -q
.venv/bin/python -m tools.local_db stop
```

These tests use the guarded local `facetrack_test` database, mocked Auth/Storage and synthetic identities. They never use hosted Supabase.

### Flutter

Run `../../scripts/flutter analyze` and `../../scripts/flutter test` inside each of:

```text
packages/app_core
packages/capture
apps/student
apps/teacher
```

On Windows, replace `../../scripts/flutter` with `flutter`.

## 9. Configuration reference

### `services/api/.env` — private, server only

| Variable | Required | Purpose |
|---|---:|---|
| `DATABASE_URL` | Yes | Restricted `facetrack_api` runtime connection |
| `MIGRATION_DATABASE_URL` | Operator tools | Owner connection for migration/seed/provisioning only |
| `SUPABASE_URL` | Yes | Exact HTTPS project origin |
| `SUPABASE_PUBLISHABLE_KEY` | Yes | Auth/API publishable key; readiness checks it |
| `SUPABASE_STORAGE_SECRET` | Media features | Server-only `sb_secret_...` key |
| `JOIN_CODE_KEYS`, `JOIN_CODE_KEY_ID` | Yes | AES keyring for recoverable join codes |
| `TEMPLATE_KEYS`, `TEMPLATE_KEY_ID` | Biometrics | Separate AES keyring for face templates |
| `ENROLLMENT_BUCKET` | Optional override | Defaults to `facetrack-enrollment-dev` |
| `DOCUMENTS_BUCKET` | Optional override | Defaults to `facetrack-documents-dev` |
| `CORS_ORIGINS` | Yes for web | Exact JSON list; defaults to ports 5300 and 5301 |
| `ENVIRONMENT` | Yes | Development label |
| `RESEND_API_KEY`, `RESEND_FROM` | Optional | Faculty report email; blank disables delivery |
| `FACULTY_REPORT_URL` | Email only | Teacher application base URL |

### `services/worker/.env` — private, worker only

| Variable | Purpose |
|---|---|
| `API_BASE_URL` | Local API origin |
| `WORKER_TOKEN` | Scoped `ftw_...` credential |
| `REDIS_URL` | Private local broker URL |
| `MANIFEST_PATH` | Approved model manifest |
| `PROFILE_PATH` | Frozen recognition profile |
| `MEDIA_ORIGIN` | Allowed Supabase media origin |
| `TEMP_ROOT` | Private temporary job directory |

Compose overrides the API, Redis, model/profile and temporary paths with container-safe values. `MEDIA_ORIGIN` and the token still come from the private worker file.

### `.local/flutter/development.json` — public client configuration

Only `API_BASE_URL`, `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY` and `DEFAULT_INSTITUTE_ID` belong here.

## 10. Troubleshooting

### API returns `NOT_READY`

Run `docker compose logs --tail 100 api`. Confirm migration head `0007_attendance_queries`, the runtime URL uses `facetrack_api` rather than the owner, 37 tables have forced RLS, and the publishable key is configured.

### Worker repeatedly reports unauthorized or no jobs complete

Inspect `docker compose logs --tail 100 worker agent`. The 30-day worker credential may be expired or disabled. Contact the project operator; do not silently replace it or weaken worker authentication.

### Docker Compose rejects `include`

Update to Compose v2.20 or newer, or use the canonical file directly:

```text
docker compose -f compose.yaml up -d
```

### Web app says `Setup required`

The app was started without `--dart-define-from-file`, or `.local/flutter/development.json` still contains placeholders. Restart with the exact command in section 4.

### Android says Mac/connection unavailable

Reconnect USB, unlock the phone and rerun the platform `android-connect` helper. Verify `adb devices` shows `device`, then reopen the app.

### Login works but classes say access unavailable

Use the correct controlled role account. The API derives roles from approved memberships and profiles; selecting the Teacher app cannot grant Teacher access.

### Camera does not open

Allow camera permission for the correct browser origin or Android app. Close other programs using the camera. Use Chrome for the verified path. HTTPS or loopback is required for browser camera access.

### Port already in use

FaceTrack uses 8000, 5300, 5301, 5302 and optional 8010. Stop the earlier FaceTrack process; do not kill an unrelated process without checking what owns the port.

### Docker service stops immediately

Check file presence without printing contents, then inspect logs:

```text
docker compose ps
docker compose logs --tail 100 api worker agent redis
```

The most common causes are missing private files, placeholders, expired worker credentials or a model path that does not exist inside `.local/spike`.

### Windows scripts are blocked

Use a process-scoped policy in the current PowerShell only:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
```

### Supabase project is paused or unreachable

Resume the free development project in the Supabase dashboard, wait until it is healthy, and retry readiness. Do not treat provider downtime as an authentication failure.

## 11. Safe handoff checklist

Before giving the project to another user or LLM:

1. Share the repository URL.
2. Transfer the encrypted private package through a private channel; send its password separately.
3. Transfer controlled demo login details through a password manager.
4. Tell the recipient which run mode they should use.
5. Never send `.env` contents, model files, recordings, embeddings or templates through chat.
6. Ask them to report only command names, error messages and service status.

For a nontechnical Windows recipient, use [the prepared handoff prompt](CLIENT_WINDOWS_HANDOFF.md).
