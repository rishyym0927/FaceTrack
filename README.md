# FaceTrack

Student and Teacher Flutter apps for human-reviewed, face-assisted attendance. The current demo uses a **Mac-hosted FastAPI/Redis/Celery CPU worker**, a Mac or phone camera, and a **free Supabase development project** for Auth, PostgreSQL and private Storage. Teacher web runs on **5300**, Student web on **5301**, and the API on **8000**. Android reaches the Mac over USB forwarding. This is a local demo, not an institute deployment.

## Run the current demo

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
