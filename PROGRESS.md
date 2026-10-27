# FaceTrack development checkpoint

**Reviewed:** 27 October 2026 (Asia/Kolkata)

**Architecture:** [`MASTER_DESIGN.md`](MASTER_DESIGN.md)

**Setup:** [`docs/INSTALLATION.md`](docs/INSTALLATION.md)

**Milestones:** [`ROADMAP.md`](ROADMAP.md)

## Current state

The current demo is **cloud-hosted data with local processing**:

- Supabase hosts Auth, PostgreSQL and private Storage.
- FastAPI, Redis, one Celery CPU worker and the outbound agent run on the development computer.
- Teacher and Student are separate Flutter Android/web apps on ports 5300/5301.
- Android reaches the local API through USB port forwarding.

macOS Apple Silicon is the verified demo host. The canonical Docker stack supports the same local services on Windows/Linux; both Compose configurations validate and the API/worker images build, but physical Windows/Linux acceptance remains pending. HTTPS/cloud API and institute deployment are later gates.

Schema head is **`0008_admin`**, with **37 forced-RLS business tables**. The running API's `/health/ready` passes against the hosted development project, which checks exactly that head and table count.

## Implemented and verified

### Terminology, faculty dashboard and administration (27 October 2026)

- Both apps use the institute's wording from the CSE timetable: Subject, Section, Semester term, Faculty, ordinal semesters ("3rd Semester"), "Odd Semester 2026". Labels only; routes, API, roles and CSV columns are unchanged.
- Faculty home dashboard: overall attendance, semester filter and semester-wise bars, sortable subject-wise statistics with drill-down, distribution chart, below-75% attention list, semester CSV export. Built in the app from the existing summary endpoint.
- Admin tab: setup checklist with the next step and jump-to-form, statistics, login-account and by-semester charts, institute-wide attendance, guided forms with institute examples, lists of existing records, searchable faculty/student directories, role grant by person picker.
- Verified by widget tests at 360/768/1440 px with 200% text. **Not yet seen in an authenticated browser or on the phone**; the running 5300/5301 dev servers were not reloaded with these changes.
- Theory/Lab and lab batches (A1, B1) from the timetable are not modelled.

### Accounts and classes

- Approved student/teacher identities, memberships and teacher assignments
- Student identity claim, join-code request and teacher approval
- Tenant/object authorization, encrypted join codes, idempotency and rate limits
- Student/Teacher web and Android class flows
- Session restoration/logout, invalid-code recovery and Teacher web keyboard/screen-reader navigation

### Biometric enrolment

- Versioned consent and guided Android/Chrome capture
- Private signed Supabase upload and durable local processing
- Encrypted 512D templates pinned to model/profile versions
- Teacher identity/pose review before activation
- Two consenting approved class members currently have active templates
- One complete real happy path is verified; a second active student was user-confirmed
- Android upright preview/playback and correct left/right pose guidance are user-confirmed

Recovery/lifecycle acceptance remains open for interrupted upload, worker restart, rejection, replacement, withdrawal, expiry and all capture edge cases.

### Sessions and attendance

- Manual/scheduled sessions, frozen roster and private classroom capture
- Roster-scoped recognition suggestions and evidence-coded drafts
- `proposed_absent` is shown as **Not recognized**. Since 27 October (client request) the Teacher review pre-fills these rows as a draft **Absent** that the teacher can change; it becomes final only when the teacher publishes. Widget/unit-tested only, not yet seen signed in
- Failed/limited processing and missing templates remain Unassessed
- Explicit teacher decisions, immutable publication revisions and corrections
- Student own published history
- Student Absent-attendance query and assigned-teacher accept/reject flow, locally tested

One real low-light two-person capture sampled 12 frames, produced 23 detections and 14 quality rejects, and suggested one of two enrolled students. The teacher explicitly confirmed both students Present and published revision 1. Raw capture media was deleted. Worker pipeline time was **356.505 ms**, excluding upload, queue, network, UI and cold start; it is not an end-to-end response measurement.

### Timetable and reports

- Bounded 14-column CSV upload, validation preview and selected-day materialization
- Room, faculty, class and overlap checks; repeated import is idempotent
- One real Monday scheduled session was user-confirmed
- Draft/final CSV and PDF report jobs from immutable snapshots
- Private 60-second authorized downloads; final CSV/PDF contents user-confirmed
- Email delivery code exists but is disabled because no permitted Resend sender is configured

### ML and evaluation

- Frozen SCRFD-500M + ArcFace-trained MobileFaceNet baseline, CPU ONNX Runtime
- Bounded video decoding, face quality checks, alignment, normalized embeddings, exact NumPy roster matching and temporal corroboration
- Freeze receipt verifies 16 source/model/profile/template/lock files
- Six calibration scenarios passed; independent real held-out acceptance remains **1 of 6**
- Isolated research package covers detector-only CLAHE, contrast/yaw candidates, two-scale SCRFD and per-crop alignment rejection without modifying production files
- DigiFace 60-scene synthetic benchmark: baseline 22/60 present suggestions and zero wrong-present marks; two-scale 24/60 and zero wrong-present marks; CLAHE unchanged; contrast filter worse
- Synthetic steady walk-around, class of 70 cooperative students plus 15 absent roster members and 3 intruders, frozen model unchanged, 10 runs each (`experiments/ml_accuracy/run_phone_walk.py --steady --face-cap 180 --frames 210`): each student in view about 4 s in total (`--dwell 4`) gave 91.4% recognised (84–97%); about 4 s on each side (`--dwell 8`) gave 96.6% (93–99%); zero false presences, intruder matches or confusions. Result files are in ignored `.local/experiments/phonewalk-4s/`. This is synthetic DigiFace data, not classroom accuracy.
- Synthetic results are not classroom accuracy. No >95% accuracy, liveness, ≤2-second end-to-end response or 20-class capacity claim is established.

The loopback Model Test Console lets a nontechnical tester enrol consenting volunteers and run six scenarios. Its automated tests and synthetic smoke pass; real-camera volunteer and Windows acceptance are pending.

## Verification on 27 October 2026

| Check | Result |
|---|---|
| API PostgreSQL suite | **50 passed** |
| API Ruff | Passed |
| Worker suite | **35 passed** |
| Worker Ruff | Passed |
| Root ML/contract suite | **42 passed, 1 expected frozen-baseline limitation** |
| ML freeze receipt | **16/16 unchanged** |
| Shared Flutter (`app_core`) | Analyze clean; **34 passed** |
| Capture Flutter | Analyze clean; **8 passed** |
| Student Flutter | Analyze clean; **10 passed** |
| Teacher Flutter | Analyze clean; **47 passed** (re-run after the Absent pre-fill) |
| OpenAPI contract | Regenerated; includes the admin and attendance-summary endpoints |
| Running API | `/health/live` and `/health/ready` return 200 |
| Hosted database | `public.alembic_version` read directly: `0008_admin` |
| Teacher web build | `flutter build web` with the configured public file succeeds |
| Upgrade-guide model check | `load_manifest` + `load_profile` print "model and profile OK" natively and inside the worker image |
| Not re-run today | Student web build, Android APK builds, Docker image rebuilds, PowerShell syntax (no `pwsh` on the Mac), physical-device and authenticated visual checks |

The configuration audit also removed whole-file API environment injection from Compose. The mounted API `.env` still supplies declared runtime settings through Pydantic, and explicit operator tools can read `MIGRATION_DATABASE_URL`; the running API process no longer receives that owner URL as an exported environment variable.

The root suite's expected failure records the frozen baseline's degenerate-landmark alignment behavior. The isolated candidate fixes this per crop, but the production freeze is unchanged.

## Current blockers and next actions

1. Run the Model Test Console with 2–3 consenting adults on the demo camera; preserve its aggregate `.txt` and `.json` reports.
2. Complete the five missing independent real scenarios: one enrolled person absent, unknown alone, known plus unknown, varied distance/position, and no face.
3. Exercise attendance-query accept/reject on authenticated web and Android using safe controlled records.
4. Complete biometric lifecycle/recovery checks and a full restart rehearsal.
5. Perform a physical Windows x64 run; record Docker, camera, web and worker results. Repeat on Linux only if it will be demonstrated.
6. Configure/test Resend only after a permitted sender exists.
7. Keep the existing detector/profile for the presentation. Adopt no research candidate until real held-out accuracy, latency, rights and reliability gates pass.
8. Sign in as faculty and as an admin, and check the new dashboard and Admin tab on web and on the phone before relying on them in a presentation.
9. Later: inspect the latest release web bundles and APKs on an idle phone (carried over from the 25 October review).
10. Later, before institute scale: benchmark recognition input, which fetches templates one roster member at a time (`services/api/app/recognition_jobs.py`), before batching it.

## Setup and privacy notes

- The public repository cannot run real inference by itself. Private `.env`, model, profile and demo credentials must be provisioned or securely transferred.
- Do not regenerate the existing worker token on routine startup; it is scoped and time-limited.
- Never commit credentials, tokens, recordings, embeddings, templates, ONNX files or participant-level results.
- Raw-media cleanup and job reconciliation run only while the local agent is awake. Inspect backlog after restart.
- Public signup/recovery, admin UI, iOS/native desktop, cloud inference, backups/restore acceptance, model deployment rights and institute-scale load testing remain later work.

## Frozen prototype evidence

Private manifest `.local/spike/models/buffalo_sc/manifest.json`, profile `.local/spike/profiles/frozen-phase1b-v1.json`, templates `.local/spike/experiments/calibration-v3` and receipt `.local/spike/held-out-freeze-v2.json` remain outside Git. One fresh both-known Test clip passed three fresh-process repeats without changing the receipt. Five independent scenarios remain. Never tune on those held-out clips.
