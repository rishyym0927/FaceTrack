# FaceTrack development checkpoint

**Reviewed:** 9 November 2026 (Asia/Kolkata)

## 9 November client console report

- User supplied aggregate `.json` and `.txt` reports from the hosted client Model Test Console (generated 08:26 UTC). All six first scored scenarios passed with zero false-presence suggestions, zero misses and the same result across three runs per clip; no rejected recordings were reported. Per-run processing ranged about 4.2–11.2 seconds; whole scenario checks took 19.8–37.8 seconds including repeats and overhead, not upload/UX latency. The report's model pin was healthy but its separate freeze receipt checked 0 files. Final enrolled count was 2, while two scenario records show a roster of 3, consistent with a volunteer being removed after those runs; the aggregate alone cannot establish the sequence or independently verify consent/ground truth. This is controlled console evidence, not the previously tracked independent held-out 1/6 acceptance or classroom accuracy.

## 8 November audit and integration checkpoint

- **9 November client console review/deployment:** Compared Student web/Android enrolment with the client console. Console now shares the FaceTrack theme, has guided progress and clearer result explanations, lets clients choose an enumerated camera before recording and play back a clip before submission. It retains timed pose prompts; unlike Student enrolment, it does not analyze preview poses live. Backend now isolates concurrent upload temp files, holds the scoring lock until results are stored, and never reuses volunteer IDs while a session's history remains. Teacher Flutter 78 passed and analyze clean; worker 56 passed and Ruff clean. The `client-01` HTTPS page and backend were updated with zero volunteers present; authenticated page/status returned 200, anonymous page 401, model pin healthy and product readiness 200. No real client camera/volunteer acceptance was performed.
- A separate HTTPS Model Test Console workspace was provisioned as `client-01` on the Azure VM. It has its own container, named data volume and HTTP Basic login; credentials are stored only in ignored `.local/clients/client-01.txt`. Anonymous page, API and script requests returned 401; authenticated page/API returned 200; the model pin check passed and the workspace has zero volunteers. Product readiness remained 200. No real client recording or consent has been completed. Commercial/institute model rights remain unverified, so do not distribute the login for those uses.
- The Model Test Console web build and loopback-only container were installed on the Azure VM. An SSH tunnel from the Mac returned a healthy status and served the page; the public `/console/` path returned 404. `scripts/console-azure` starts/opens the private tunnel and has a stop command. VM pin check passed but the separate 16-file freeze receipt is absent on the VM; real volunteer scenarios remain unrun. See `docs/MODEL_TEST_CONSOLE.md`.
- Commit `5d126b7` was deployed to the Azure VM on 8 November: Teacher and Student web builds succeeded; API, Redis, worker and agent are healthy; public `/health/ready`, `/teacher/` and `/student/` return 200. The audited Caddyfile was validated and reloaded, and its web security headers were observed. This verifies service availability, not an authenticated end-to-end flow.
- Follow-up camera review found no camera selector in either app. A new pre-recording selector is implemented for Student/Teacher, including external devices when enumerated by the OS/browser. Commit `19285fc` was pushed; both web apps were rebuilt and uploaded on 8 November, and live URLs returned 200 with the Student camera script observed. The Android app was not rebuilt or installed. Switching during an active recording remains unsupported and disabled to preserve one clip; physical external-camera acceptance is open. Student attendance advice and zero-assessment status were corrected with a regression test.
- Independent ML review on the Mac: frozen receipt 16/16, pinned model executes with CPU ONNX, root suite 42 passed/1 expected xfail. Real held-out scenarios remain 1/6; model rights for institute use remain unverified. See `docs/MODEL_TEST_CONSOLE.md` for the six-scenario procedure.
- Security review found an admin Auth email-collision path that could reset and link an existing account. The uncommitted fix refuses existing accounts, cleans up newly created accounts after a link failure, and adds a regression test. Biometric review cursors are now scoped to the authorized offering.
- Faculty attendance sorting now exposes accessible labels and direction. Azure deployment waits for backend readiness before replacing live web assets; Caddy adds basic security headers.
- Local checks: API 57 passed after security fixes; worker 54 passed; root ML 42 passed, 1 expected xfail; shared Flutter 66 passed, capture 8 passed, Student 19 passed, Teacher 76 passed; teacher analyze, Ruff, shell syntax, diff whitespace, and ML freeze receipt passed. These are local checks, not hosted or physical-device acceptance.
- Existing uncommitted feature work was preserved. Authenticated web/Android walkthrough, full Azure deployment rehearsal, real recognition scenarios, biometric recovery, and institute gates below remain open.

**Architecture:** [`MASTER_DESIGN.md`](MASTER_DESIGN.md)

**Setup:** [`docs/INSTALLATION.md`](docs/INSTALLATION.md)

**Milestones:** [`ROADMAP.md`](ROADMAP.md)

## Current state

The demo runs **online on one Azure VM** (27 October 2026, see [docs/DEPLOY_AZURE.md](docs/DEPLOY_AZURE.md)):

- Supabase hosts Auth, PostgreSQL and private Storage.
- The VM (Central India, B2as_v2) runs FastAPI, Redis, one Celery CPU worker and the outbound agent in Docker, with Caddy HTTPS in front, and serves both web apps at `https://facetrack.centralindia.cloudapp.azure.com/teacher/` and `/student/`.
- Verified: HTTPS health ready, both web apps load, the model and profile load in the VM worker, the agent is authorized and polling. **Not yet verified: a signed-in end-to-end enrolment and recognition run through the VM.**
- Only one processing backend may run at a time; the Mac's worker and agent are stopped. Local development still works on ports 5300/5301 against the local API, and Android debug APKs pointing at the VM are built (not installed).

macOS Apple Silicon is the verified demo host. The canonical Docker stack supports the same local services on Windows/Linux; both Compose configurations validate and the API/worker images build, but physical Windows/Linux acceptance remains pending. Institute deployment (model rights, monitoring, backups) remains a later gate.

Schema head is **`0008_admin`**, with **37 forced-RLS business tables**. The running API's `/health/ready` passes against the hosted development project, which checks exactly that head and table count.

## Implemented and verified

### Terminology, faculty dashboard and administration (27 October 2026)

- Both apps use the institute's wording from the CSE timetable: Subject, Section, Semester term, Faculty, ordinal semesters ("3rd Semester"), "Odd Semester 2026". Labels only; routes, API, roles and CSV columns are unchanged.
- Faculty home dashboard: overall attendance, semester filter and semester-wise bars, sortable subject-wise statistics with drill-down, distribution chart, below-75% attention list, semester CSV export. Built in the app from the existing summary endpoint.
- Admin tab: setup checklist with the next step and jump-to-form, statistics, login-account and by-semester charts, institute-wide attendance, guided forms with institute examples, lists of existing records, searchable faculty/student directories, role grant by person picker.
- Verified by widget tests at 360/768/1440 px with 200% text. **Not yet seen in an authenticated browser or on the phone**; the running 5300/5301 dev servers were not reloaded with these changes.
- Theory/Lab and lab batches (A1, B1) from the timetable are not modelled.
- Sign-in page redesigned for both apps (split branded layout on wide screens, compact header on phones).
- Home pages simplified for both apps: greeting banner with the main actions, a "Needs your attention" card (top three notifications), compact tappable subject rows; the faculty attendance overview follows the subject list. Widget-tested only; not yet seen signed in.
- Bug fixes (31 October): session lists, student attendance history and query lists are newest-first (they were in random UUID order); a failed capture upload now shows its reason inside the capture panel and keeps the clip for retry; after processing, the capture panel explains frame quality (e.g. "Only 1 of 12 faces were clear enough") with retake tips, and Unassessed rows say why (no approved face enrolment / too few clear frames); the worker agent says "Worker credential rejected or expired" instead of "waiting" on 401/403; `deploy/azure/deploy.sh` starts a deallocated VM, allows SSH from the current IP and replaces the code tree cleanly. API, worker and Flutter tests pass; not yet seen signed in.
- Attendance UX and list fixes (31 October, later): **three final states** (Present, Absent, Unassessed). The API rejects new late/excused decisions and corrections (422); older late/excused rows show as Present/Unassessed in both apps and in worker reports; no migration. The home "Needs your attention" card now lists unread updates too, so it never says "nothing needs your attention" while the bell shows a count, and it has "Mark all read". New Student **Attendance** tab: overall ring, Present/Absent/Unassessed, classes needed to reach 75% or that can be missed, per-subject bars, last-6-months chart, subject/period/status filters, records by month. Richer **Account** page for both apps: profile header, details with copy, role-specific stats (Student: subjects, attendance, face enrolment; Faculty: subjects, classes, students, below-75%) and recent activity. More API lists are in a stable order (subjects by code, roster by enrolment number, own enrolments newest first, enrolment review oldest first, terms/courses/sections); admin directories now page past 200 with a cursor; a correction between pages no longer stops student history from loading, and history is ordered by class date. API (56), worker (38) and Flutter app_core/student/teacher tests and analysis pass. **Not yet seen signed in in a browser or on the phone; not deployed.**
- Admin console redesign (31 October): gradient header with a setup-progress ring and **Take the tour**; side menu (tabs on phones) for Overview, Academic setup, People, Access; Overview with a next-step card, a setup timeline, quick actions, statistics and charts; academic setup as four step cards whose Add stays locked (with the reason) until its prerequisite exists; People as Faculty/Students directories with search and a Needs-login filter; Access as two explained cards. Forms open in dialogs (full screen on phones), show errors inside the form and close on success; temporary passwords are hidden with a show/hide toggle (the create form showed them in clear text). ⓘ tips explain each term. A guided tour (11 steps, spotlight overlay, Back/Next/Skip, arrow keys and Esc) starts on an admin's first visit (per account, per device) and can be replayed. Directories now load every page. API unchanged. Widget-tested at 360/768/1440 px with 200% text, tour included; **not yet seen signed in**.
- Page transitions (31 October): one motion system for both apps. Tabs fade through each other; a subject or session page slides in from the right and back reverses it; reduced-motion shows pages instantly; the same transition on every platform (web had the host OS slide). Subject pages are nested under the list (URL unchanged), so going back keeps the list's state and scroll instead of reloading it, and the back buttons return to wherever the page was opened from (e.g. Attendance). Widget-tested; not yet seen on a phone.
- UX review fixes (31 October): a branded loading screen in both web apps while the app downloads (and the missing viewport tag, so it fits phones); pull-to-refresh on Subjects, Attendance, subject history, notifications, the faculty home and subject page, and Admin (not the session page, where it would drop unsaved decisions); student history says "Corrected by faculty" instead of "Publication revision N"; faculty subject tabs show counts of sessions to review, join requests, face reviews and open queries. Tests pass; loading screen checked in a phone-sized browser; signed-in screens not yet seen.
- Faculty subject page redesign (31 October): banner with subject code, section and term chips, live counts (students, sessions, to review) and Join code; a "Needs you" strip whose chips jump to the right tab; icon tabs with counts (Sessions, Students, Face reviews, Queries, Overview; join requests now sit at the top of Students); sessions grouped into Needs your action / Upcoming / Published / Cancelled with filters, a calendar tile, time range, room and a status pill, with the main action on each card; timetable import opens in a dialog. Pages opened from a list now show their own URL (a refresh lands on the same page). Widget-tested at 360 and 1280 px; not yet seen signed in.
- Faculty session page and home (31 October): the session page has a banner with the subject, date, time range, room, section and state; a step tracker (Open → Record → Close → Review → Publish) with one sentence for the current step; spaced panels and an icon for the capture state; a bar pinned to the bottom while reviewing with live Present/Absent/Unassessed/To check counts and Save/Publish; a publish confirmation that states the counts; "Published · corrected N times" instead of revision numbers; and a Reports heading. Faculty home subject cards show what is waiting (sessions to review, join requests, face reviews, open queries), "All caught up" or the next class (first 20 subjects, like the bell). Widget-tested at 360/768/1280 px with 200% text; not yet seen signed in.
- Review screens, reports, enrolment and notifications (31 October): Face reviews and Queries use review cards (initials, review-by deadline in red when under 24 h, frame counts, the identity and five-pose checklist; for queries the class date, "Published as Absent" and the student's reason in a quote box). Session reports are cards: final or draft, version, when created, Download PDF / CSV, email state in plain words. Student face enrolment shows an icon for each state and groups Discard and Withdraw consent under "Manage your enrolment", each with an explanation. Notifications group updates by Current / Today / Yesterday / This week / Earlier, swipe marks a notice read, and opening one returns to the list on back. Tests pass; not yet seen signed in.
- The hosted worker credential expires on **22 November 2026**; reissuing it is an owner action.
- Recording coach in the capture panel: pre-recording checklist and "Recognised so far: N of M students with face enrolment" after each processed clip.
- Signed release APKs (arm64: Teacher about 22 MB, Student about 34 MB, pointing at the Azure API) built from `origin/main`; signature verified with apksigner. Not installed on a phone yet.
- Not done: admin password reset (safe cross-institute checks need a new SECURITY DEFINER function, i.e. a migration, which was declined on 31 October).
- In-app notifications (bell with unread badge, `/notifications` panel) for students (enrolment decisions, face-enrolment state, newly published attendance, below-75% subjects, resolved queries), faculty (join requests, face reviews, open queries, sessions to review and publish, long-open sessions) and admins (setup and missing logins). Derived on the device from existing endpoints; no server-side store, push or email. Read state is per account on each device. Faculty checks cover the first 20 subjects. Unit- and widget-tested only; not yet seen signed in.

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
| API PostgreSQL suite | **54 passed** |
| API Ruff | Passed |
| Worker suite | **37 passed** |
| Worker Ruff | Passed |
| Root ML/contract suite | **42 passed, 1 expected frozen-baseline limitation** |
| ML freeze receipt | **16/16 unchanged** |
| Shared Flutter (`app_core`) | Analyze clean; **54 passed** (incl. sign-in, notification and home layouts at 360/768/1440 px, 200% text) |
| Capture Flutter | Analyze clean; **8 passed** |
| Student Flutter | Analyze clean; **14 passed** |
| Teacher Flutter | Analyze clean; **55 passed** |
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
