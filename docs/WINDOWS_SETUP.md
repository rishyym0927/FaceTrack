# Run FaceTrack on Windows

This is the supported Windows development path. Flutter runs natively so Chrome/Edge and an Android phone work normally. FastAPI, Redis, Celery and the ML worker run in Linux containers through Docker Desktop. This matters because Celery and Redis do not support a dependable native Windows development setup.

## 1. Install once

Install these tools, then restart PowerShell:

- [Git for Windows](https://git-scm.com/download/win)
- [Flutter stable](https://docs.flutter.dev/get-started/install/windows), with `flutter\bin` on `PATH`
- [Docker Desktop](https://docs.docker.com/desktop/setup/install/windows-install/) using the WSL 2/Linux container engine
- Chrome or Edge
- Optional Android testing: Android SDK Platform-Tools and a data-capable USB cable

Check the installation in PowerShell:

```powershell
git --version
flutter doctor
flutter devices
docker info
```

Flutter must list `chrome` or `edge`. Docker must report a running Linux engine.

## 2. Clone and prepare

```powershell
git clone https://github.com/rishyym0927/FaceTrack.git
cd FaceTrack
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\windows\setup.ps1
```

The setup script downloads locked Flutter packages, creates safe configuration templates, and builds the Linux service images. It does not download private model weights or invent credentials.

## 3. Add private configuration

The application needs these ignored files:

| File | Purpose |
|---|---|
| `services/api/.env` | Database, Auth, Storage and encryption configuration |
| `services/worker/.env` | Scoped worker token and media origin |
| `.local/flutter/development.json` | Public Supabase URL/key, API URL and demo institute ID |
| `.local/spike/models/buffalo_sc/` | Approved academic model artifacts and manifest |
| `.local/spike/profiles/frozen-phase1b-v1.json` | Frozen matching profile |

For the existing authorized demo, securely copy these files from the configured development machine to the same paths. Do not use Git, chat, email or a public drive for credentials, model files, recordings, templates or participant results. The Flutter file contains public client configuration, but it remains ignored so environments cannot be mixed accidentally.

For a new Supabase development project, fill the templates created by `setup.ps1`, then follow the one-time provisioning sequence in [the backend guide](../services/api/README.md). Run its Python tools inside the API container by replacing `.venv/bin/python` with:

```powershell
docker compose -f compose.windows.yaml run --rm api /opt/venv/bin/python -m tools.MODULE_NAME
```

For example, the hidden Auth-key prompt is:

```powershell
docker compose -f compose.windows.yaml run --rm api /opt/venv/bin/python -m tools.configure_auth
```

Provisioning is an operator task. Do not rerun seeding or worker provisioning for the existing demo project.

## 4. Start the complete application

```powershell
.\scripts\windows\start-demo.ps1
```

The script starts Redis, API, Celery and the agent in Docker, waits for API readiness, then opens two PowerShell windows:

- Teacher web: <http://localhost:5300>
- Student web: <http://localhost:5301>
- API readiness: <http://127.0.0.1:8000/health/ready>

If only Edge is installed:

```powershell
.\scripts\windows\start-demo.ps1 -Browser edge
```

To inspect a failure:

```powershell
docker compose -f compose.windows.yaml ps
docker compose -f compose.windows.yaml logs --tail 100 api worker agent redis
```

Stop the backend with:

```powershell
.\scripts\windows\stop-demo.ps1
```

Close the two Flutter PowerShell windows separately.

## 5. Run on an Android phone

Enable Developer options and USB debugging, connect and unlock the phone, then run:

```powershell
.\scripts\windows\android-connect.ps1
flutter devices
cd apps\student
flutter run -d PHONE_DEVICE_ID --dart-define-from-file=..\..\.local\flutter\development.json
```

Use `apps\teacher` for the Teacher app. Repeat `android-connect.ps1` after reconnecting the cable. The phone depends on USB forwarding while the API remains local.

Presentation builds use the same public configuration:

```powershell
cd apps\student
flutter build web --dart-define-from-file=..\..\.local\flutter\development.json
flutter build apk --debug --target-platform android-arm64 --dart-define-from-file=..\..\.local\flutter\development.json
cd ..\teacher
flutter build web --dart-define-from-file=..\..\.local\flutter\development.json
flutter build apk --debug --target-platform android-arm64 --dart-define-from-file=..\..\.local\flutter\development.json
```

## 6. Safe verification

Run frontend checks natively:

```powershell
cd apps\student
flutter analyze
flutter test
cd ..\teacher
flutter analyze
flutter test
```

Run the worker tests in its Linux container:

```powershell
docker compose -f compose.windows.yaml run --rm worker /opt/venv/bin/python -m pytest tests -q
```

Backend tests use a guarded, disposable PostgreSQL cluster rather than the hosted project. Contributors who need them should also install Python 3.11, [uv](https://docs.astral.sh/uv/getting-started/installation/) and PostgreSQL 16 with `initdb`/`pg_ctl` on `PATH`, then run:

```powershell
uv sync --project services/api --locked --python 3.11
cd services\api
.venv\Scripts\python -m tools.local_db start
.venv\Scripts\python -m pytest tests -q
.venv\Scripts\python -m tools.local_db stop
```

These automated checks do not establish recognition accuracy. Real recognition still requires approved weights, private configuration and consenting test participants.

## Common fixes

- **Docker daemon unavailable:** start Docker Desktop and wait until its engine is ready.
- **API never becomes ready:** verify `services/api/.env` has no placeholders and use `docker compose -f compose.windows.yaml logs api`.
- **Worker keeps restarting:** verify the model manifest/profile exist and `services/worker/.env` contains the current scoped token.
- **Browser missing:** run `flutter devices`, then choose `-Browser chrome` or `-Browser edge`.
- **Phone cannot reach API:** keep USB connected and rerun `android-connect.ps1`.
- **Ports already in use:** stop the earlier FaceTrack processes before retrying; the fixed demo ports are 8000, 5300 and 5301.

Windows execution is designed and scripted, but it remains an acceptance item until the complete flow is exercised on a physical Windows host. The current verified demo host is macOS.
