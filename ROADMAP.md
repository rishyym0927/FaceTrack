# FaceTrack build checklist

**Demonstration target:** 28 October 2026.

**Current step:** preserve the working demo, complete safe authenticated acceptance/recovery, run the available real recognition tests and rehearse.

**Source of execution truth:** [`PROGRESS.md`](PROGRESS.md).

Check a milestone only after its required outcomes are verified. Implemented code or passing synthetic tests alone do not close a real-world gate.

## Demonstration milestones

- [ ] **1. ML proof of concept**

  Tooling, capture, model provisioning, templates, calibration and evaluation are implemented. One of six independent real scenarios has passed. Complete the other five with consenting participants without tuning on held-out clips. Synthetic DigiFace results and Model Test Console runs remain clearly labelled.

- [x] **2. Backend foundation**

  FastAPI, hosted Supabase Auth/PostgreSQL, restricted runtime role, 37 forced-RLS tables (migration head `0008_admin`), approved identities, academics, join codes, requests/approval, audit, idempotency and rate limits are implemented and verified.

- [x] **3A. Flutter account and class flows**

  Separate Student/Teacher Android and web apps, shared auth/design, identity claim, classes, join requests, teacher approval, session restoration/logout and invalid-code recovery are verified.

- [ ] **3B. Student biometric enrolment**

  Consent, guided capture, private upload, durable local processing, encrypted templates and supervised activation are implemented. The real happy path and two active class members are verified. On 10 November 2026 the user confirmed upright recording preview and working live guidance on Samsung SM-M356B with signed build `1efb093`. Repeat the [signed Android camera check](docs/CAMERA_VALIDATION.md#student-android-signed-release-check) for relevant releases. Complete interrupted upload, worker restart, rejection, replacement, withdrawal, expiry, no/two-face, low-light, denied-camera and retention recovery.

- [ ] **4. Teacher attendance**

  Sessions, frozen rosters, classroom capture and recognition drafts are implemented. One low-light session was human-reviewed and published. Complete better-lit both-known, absent, unknown, mixed, variation and poor/no-face acceptance while leaving failures unassessed.

- [ ] **5. Review, history and attendance queries**

  Teacher decisions, immutable publication/correction, Student own history and attendance-query APIs/UI are implemented and locally tested. Complete safe authenticated web/Android query acceptance and remaining negative permission checks.

- [ ] **6. Timetable and reports**

  One real CSV timetable occurrence and final CSV/PDF downloads are verified. Keep email delivery open until a permitted Resend sender and recipient test exist.

- [ ] **6A. Institute terminology, faculty dashboard and administration**

  Institute wording, the faculty attendance dashboard and the guided Admin tab are implemented and widget-tested. Close after an authenticated faculty and admin walkthrough on web and on the phone.

- [ ] **7. Integration and presentation readiness**

  Complete restart/retry rehearsal, private-media cleanup inspection, authenticated visual/device checks, physical Windows acceptance if it will be used, and two full demo rehearsals. Freeze optional work before presentation day.

## Before 28 October

1. Verify frozen receipt and service health.
2. Run available consented real recognition cases; report failures honestly.
3. Exercise one controlled attendance query through teacher resolution.
4. Rehearse login → class → enrolment/session → review → publication → history/report.
5. Confirm the private package and [installation guide](docs/INSTALLATION.md) recover the demo after restart.
6. Keep report downloads available; do not block the demo on email.

## After the demonstration

- [ ] Obtain model rights for institute deployment.
- [ ] Deploy HTTPS API and always-on worker capacity.
- [ ] Run a supervised multi-room classroom pilot and measure accuracy/coverage.
- [ ] Benchmark queue delay, memory and throughput for 20 concurrent classes.
- [ ] Add automatic timetable scheduling/reconciliation.
- [ ] Configure backups, restore tests, monitoring/Sentry and CI/CD.
- [ ] Add public registration/recovery and web-only administration after institute policy approval.

**Working rule:** real inference only for demonstrations; processing failure never becomes absence; teachers publish authoritative attendance; every accuracy, latency and capacity target requires measurement.
