# FaceTrack

FaceTrack is a human-reviewed, face-assisted attendance system with separate Student and Teacher Flutter apps. Students join approved classes and enrol a face template with consent. Teachers create sessions, upload short classroom videos, review recognition suggestions, publish attendance and download CSV/PDF reports.

The current demonstration uses:

- Flutter web and Android clients
- FastAPI with a restricted PostgreSQL runtime role
- hosted Supabase Auth, PostgreSQL and private Storage
- local Redis, Celery and CPU inference
- SCRFD detection and ArcFace-family 512D embeddings through ONNX Runtime
- teacher-controlled attendance publication

Face recognition never publishes attendance by itself. A missed face, processing failure or ineligible template remains unassessed until a teacher decides.

## Start here

Use the [complete installation guide](docs/INSTALLATION.md). It covers macOS, Windows and Linux, first-time Supabase provisioning, private configuration, Android, testing and troubleshooting.

Quick start for an already provisioned checkout:

```sh
docker compose up -d --build
curl -fsS http://127.0.0.1:8000/health/ready
```

Then start Teacher web on port 5300 and Student web on 5301 using the commands in the installation guide. Windows users can run:

```powershell
.\scripts\windows\start-demo.ps1
```

Private configuration and approved model files are deliberately excluded from Git. A fresh clone can run synthetic tests, but it cannot perform real recognition until an authorized operator supplies or provisions those files.

## Current status

- Schema head: `0007_attendance_queries`
- 37 business tables with forced RLS
- Account/class flows verified on web and Android
- Real consented enrolment and supervised template activation verified
- One low-light classroom session teacher-reviewed and published
- Student history, timetable import and private CSV/PDF downloads verified
- Evidence-coded Not recognized drafts and attendance queries implemented and locally tested
- Independent real recognition acceptance remains **1 of 6** held-out scenarios
- Faculty email, physical Windows/Linux acceptance, cloud deployment and institute-scale accuracy/capacity remain open

Do not claim >95% accuracy, two-second end-to-end response, liveness or 20 simultaneous classes from the current evidence.

## Repository map

| Path | Purpose |
|---|---|
| `apps/student` | Student Android/web app |
| `apps/teacher` | Teacher Android/web app, camera spike and model-test UI |
| `packages/app_core` | Shared auth, API transport, navigation and design system |
| `packages/domain_models` | Shared Dart models |
| `packages/capture` | Camera, pose guidance, pending media and resumable upload |
| `services/api` | FastAPI, authorization, migrations and provisioning tools |
| `services/worker` | Celery worker, job agent, ML integration and reports |
| `services/worker/src/facetrack_ml` | Frozen product ML pipeline |
| `experiments/ml_accuracy` | Isolated research candidates; never imported by production |
| `compose.yaml` | Canonical cross-platform local service stack |
| `contracts/openapi.json` | Generated implemented API contract |

## Documentation

- [Master design](MASTER_DESIGN.md) — architecture and product rules
- [Installation](docs/INSTALLATION.md) — canonical setup and configuration
- [Progress](PROGRESS.md) — actual verified state and blockers
- [Roadmap](ROADMAP.md) — milestone completion gates
- [Platform support](docs/PLATFORM_SUPPORT.md) — verified versus prepared targets
- [ML quickstart](docs/ML_TEAM_QUICKSTART.md) — safe contributor tests
- [Model test console](docs/MODEL_TEST_CONSOLE.md) — nontechnical volunteer evaluation

Never commit credentials, tokens, face recordings, embeddings, templates, ONNX files or participant-level results.
