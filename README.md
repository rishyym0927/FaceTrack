# FaceTrack

FaceTrack is a human-reviewed, face-assisted attendance system with separate Student and Teacher (faculty) Flutter apps. Students join their subjects and enrol a face template with consent. Faculty create sessions, upload short classroom videos, review recognition suggestions, publish attendance and download CSV/PDF reports. Admins set up semester terms, subjects, sections, faculty and students.

The current demonstration uses:

- Flutter web and Android clients
- FastAPI with a restricted PostgreSQL runtime role
- hosted Supabase Auth, PostgreSQL and private Storage
- local Redis, Celery and CPU inference
- SCRFD detection and ArcFace-family 512D embeddings through ONNX Runtime
- faculty-controlled attendance publication

Face recognition never publishes attendance by itself. A missed face, processing failure or ineligible template remains unassessed until the faculty member decides.

## Start here

Use the [complete installation guide](docs/INSTALLATION.md). It covers macOS, Windows and Linux, first-time Supabase provisioning, private configuration, Android, testing and troubleshooting.

Quick start for an already provisioned checkout:

```sh
make up          # macOS/Linux; same as docker compose up -d
make health      # API readiness
```

Then start Teacher web on port 5300 and Student web on 5301 using the commands in the installation guide. Windows users can run:

```powershell
.\scripts\windows\start-demo.ps1
```

Private configuration and approved model files are deliberately excluded from Git. A fresh clone can run synthetic tests, but it cannot perform real recognition until an authorized operator supplies or provisions those files.

## Current status

- Database: migration head `0008_admin`, 37 business tables with forced row-level security
- Student and Teacher apps (web and Android) use the institute's terms: Subject, Section, Semester term, Faculty
- Faculty home shows an attendance dashboard: overall, semester-wise and subject-wise figures, a distribution chart, a needs-attention list and a CSV report
- Admins get a guided Administration tab: setup checklist, statistics, directories, and access management
- Verified with real people: consented face enrolment and template activation; one classroom session reviewed and published; student history; timetable import; CSV/PDF downloads
- Independent real recognition acceptance: **1 of 6** held-out scenarios. Synthetic benchmarks are reported separately and are not classroom accuracy
- Still open: faculty email (no permitted Resend sender), physical Windows/Linux acceptance, cloud deployment, institute-scale accuracy and capacity

Do not claim >95% accuracy, a two-second end-to-end response, liveness detection or 20 simultaneous classes from the current evidence.

## Repository map

| Path | Purpose |
|---|---|
| `apps/student` | Student Android/web app |
| `apps/teacher` | Teacher (faculty) Android/web app, admin tab, camera spike and model-test UI |
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

- [Installation](docs/INSTALLATION.md): canonical setup and configuration for macOS, Windows and Linux
- [Client setup](docs/CLIENT_SETUP.md): first install for a nontechnical user, done by Claude Code
- [Upgrade an existing install](docs/UPGRADE_EXISTING_INSTALL.md): bring an older install up to date with full ML
- [Windows](docs/WINDOWS_SETUP.md) and [Linux](docs/LINUX_SETUP.md) checklists, and [platform support](docs/PLATFORM_SUPPORT.md)
- [Master design](MASTER_DESIGN.md): architecture and product rules
- [Progress](PROGRESS.md) and [roadmap](ROADMAP.md): verified state, blockers and milestone gates
- [ML quickstart](docs/ML_TEAM_QUICKSTART.md), [ML model and evaluation](docs/ML_SPIKE.md), [accuracy plan](docs/ML_ACCURACY_AND_ATTENDANCE_PLAN.md)
- [Model test console](docs/MODEL_TEST_CONSOLE.md) and [tester steps](docs/CLIENT_MODEL_TEST_STEPS.md): volunteer evaluation without logins
- [Project overview](docs/CLIENT_PROJECT_DOCUMENT.md) and [cost and reliability](docs/COST_AND_RELIABILITY.md): client briefing and dated planning estimates

Never commit credentials, tokens, face recordings, embeddings, templates, ONNX files or participant-level results.
