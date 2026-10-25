# FaceTrack

Student and Teacher Flutter apps for human-reviewed, face-assisted attendance. The verified demo uses a **Mac-hosted FastAPI/Redis/Celery CPU worker**, a computer or phone camera, and a **free Supabase development project** for Auth, PostgreSQL and private Storage. The implemented Windows path uses native Flutter plus Docker Desktop Linux containers; its physical-host acceptance remains pending. Teacher web runs on **5300**, Student web on **5301**, and the API on **8000**. This is a local demo, not an institute deployment.

## Choose your platform

- **Windows:** follow the beginner-friendly [Windows setup](docs/WINDOWS_SETUP.md), then run `.\scripts\windows\start-demo.ps1`.
- **Nontechnical Windows handoff:** give the client the [Claude setup prompt](docs/CLIENT_WINDOWS_HANDOFF.md) plus the private configuration package through a secure channel.
- **macOS (configured demo machine):** use the six commands below.

Private configuration, permitted model files and controlled accounts are intentionally absent from Git. A fresh clone cannot run real face processing until an authorized operator provisions them.

See the [platform support matrix](docs/PLATFORM_SUPPORT.md) before promising an operating system or browser. Current product targets are Android and web; iOS and native desktop apps are not implemented.

## Run the current demo on macOS

The existing Mac has private configuration in `.local/` and service `.env` files; Git does not include credentials, model weights, recordings or templates. On a fresh clone, follow the [backend setup](services/api/README.md) and [worker setup](services/worker/README.md) before starting. Keep the Mac awake and use a separate terminal for each process:

| Terminal | Directory | Command |
|---|---|---|
| 1 — Redis | Repository root | `redis-server .local/enrollment/redis.conf` |
| 2 — API | `services/api` | `.venv/bin/uvicorn app.main:create_app --factory --host 127.0.0.1 --port 8000` |
| 3 — Celery | `services/worker` | `.venv/bin/python -m celery -A facetrack_worker.executor:app worker --pool=solo --concurrency=1 --loglevel=WARNING --without-gossip --without-mingle` |
| 4 — Agent | `services/worker` | `.venv/bin/python -m facetrack_worker.agent` |
| 5 — Teacher web | `apps/teacher` | `../../scripts/flutter run -d chrome --web-hostname localhost --web-port 5300 --dart-define-from-file=../../.local/flutter/development.json` |
| 6 — Student web | `apps/student` | `../../scripts/flutter run -d chrome --web-hostname localhost --web-port 5301 --dart-define-from-file=../../.local/flutter/development.json` |

Check [API readiness](http://127.0.0.1:8000/health/ready) for `{"status":"ready"}`. After connecting an Android phone by USB, run `scripts/android-connect` from the repository root and keep the cable connected. The [Student](apps/student/README.md) and [Teacher](apps/teacher/README.md) guides cover debug APK builds and installation. Use the existing controlled demo accounts; public signup is not configured.

## Current state

Account/class flows, real biometric enrolment, one teacher-reviewed classroom session, student history, private CSV/PDF reports and one CSV timetable import have been verified. Broader recognition, recovery and rehearsal tests remain. Faculty email is disabled until a permitted Resend sender is configured. No production accuracy, latency or concurrency target has been established.

[Master design](MASTER_DESIGN.md) · [Progress and next actions](PROGRESS.md) · [Roadmap](ROADMAP.md) · [Detailed ML spike guide](docs/ML_SPIKE.md)

New ML contributors: [quickstart and safe test commands](docs/ML_TEAM_QUICKSTART.md).
