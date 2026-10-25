# FaceTrack application review

Reviewed 24 October 2026. Baseline commit: `268b507`; the working tree also contained the approved, uncommitted presentation redesign. This is the single issue register, not an architecture replacement.

## Scope and evidence

Reviewed shared authentication/API/navigation, Student classes/enrolment/history, Teacher class/review/session/timetable/report flows, capture adapters, API authorization/transactions/idempotency, biometric activation, publication, scoped recognition jobs, and worker dispatch/cleanup. Review combines source tracing and synthetic regression tests; it is not an exhaustive security audit or institute-scale benchmark.

Baseline: isolated PostgreSQL/API **41 passed**; worker **5 passed**. Shared Flutter baseline exposed enlarged-text sign-in overflow and three failing widget cases. Student/Teacher tests and web builds had passed before this broader review. The capture suite and new responsive/race regressions are tracked below. No participant consent, identity approval, attendance publication or hosted data mutation is part of this review.

Severity: Critical = unauthorized access, biometric exposure or destructive corruption; High = broken essential flow or unsafe authoritative effects; Medium = recoverable defects, accessibility failures or demonstrated performance waste; Low = minor usability/cosmetic inconsistency.

## Critical and high findings

No confirmed Critical or High backend defect was established by this review. Existing tests exercise tenant isolation, consent/revocation, leases, immutable publication, retry effects and report ownership. This is not a guarantee that undiscovered defects do not exist. No backend/schema change is justified solely by this review.

## Medium findings

### FT-01 — Auth banner overflows at enlarged text
- **Type/status:** Confirmed defect; fixed and regression-verified.
- **Evidence:** `packages/app_core/lib/src/product_app.dart`, `AuthFrame`; existing narrow large-text login test reports horizontal and vertical RenderFlex overflow. Brand row is unconstrained and mobile banner has fixed height.
- **Impact/reproduction:** Enlarged text on a narrow screen clips branding and disrupts login/identity/access screens.
- **Fix:** Flexible brand text, content-sized mobile banner, sufficient scroll access; preserve field labels and actions.
- **Verification:** Existing core tests plus width 360/390/768/1440 and 200% text scenarios.

### FT-02 — Report refresh overlap and stale results
- **Type/status:** Confirmed code defect; fixed and regression-verified.
- **Evidence:** `apps/teacher/lib/teacher_reports.dart`, `refresh`, periodic timer and `didUpdateWidget`. Concurrent requests have no single-flight or resource-generation guard; metadata is accumulated without clearing removed entries.
- **Impact/reproduction:** Slow response plus manual/timer refresh can overwrite newer state; widget reuse for another session can display stale reports.
- **Fix:** Coalesce same-resource refreshes, invalidate old-resource responses, refresh after mutations, clear stale data on access denial, pause background polling and dispose lifecycle listeners.
- **Verification:** Delayed synthetic requests, session switch, repeated refresh, denied access and disposal.

### FT-03 — Student attendance summary bypasses page generation protection
- **Type/status:** Confirmed code defect; fixed and regression-verified.
- **Evidence:** `apps/student/lib/student_history.dart` sets `summary` inside the fetch callback before `PagedController` accepts the response. Failed authorization clears list items but leaves the aggregate summary.
- **Impact/reproduction:** Out-of-order refresh can combine an old percentage with current rows; access denial can leave an old aggregate visible.
- **Fix:** Apply summary only for the latest mounted fetch, and clear it on authorization/not-found failures.
- **Verification:** Delayed responses and a successful load followed by 403.

### FT-04 — Header/action responsiveness lacks meaningful coverage
- **Type/status:** Confirmed coverage gap; responsive fix and matrix verified. Authenticated visual coverage remains partial.
- **Evidence:** `PageHeader` uses an unconstrained eyebrow row and fixed desktop breakpoint; Student enrolment test was expanded to 800×1000 instead of validating smaller layouts.
- **Impact:** Long labels or 200% text may overflow or push essential actions out of practical reach.
- **Fix:** Constrain/wrap labels and actions, make task headers compact, exercise scrolling at actual phone widths rather than enlarging all tests.
- **Verification:** Matrix of widths and text scales, long course name, header actions, empty state and consent/replacement access.

### FT-05 — Report polling makes 1 + N requests per cycle
- **Type/status:** Confirmed performance pattern; optimized and regression-verified within the existing API.
- **Evidence:** Every report refresh fetches the list then all detail resources; polling runs every eight seconds while pending reports exist.
- **Impact:** Repeated unchanged draft metadata consumes network/API work; no institute-scale performance claim is made.
- **Fix:** Fetch details only when needed for published email/delivery status; bound overlap and pause background polling. Preserve live final-delivery status rather than cache it indefinitely.
- **Verification:** Count list/detail calls for draft and final reports in regression tests.

## Low findings and design work

### FT-06 — Inconsistent task hierarchy
- **Type/status:** Design improvement; implemented and build-verified. Full authenticated visual acceptance remains pending.
- **Evidence:** Shared theme plus Student/Teacher pages: plain history summaries, raw report status strings, repeated large headers and inconsistent spacing between panels.
- **Fix:** Retain deep teal overview headers, use compact task headers, consistent semantic status badges, readable history summary, clear report actions and separated surfaces. Short transitions respect reduced motion; camera remains unaffected.
- **Verification:** Flutter analysis, app tests, configured builds and visual inspection. No invented counts or attendance claims.

### FT-07 — Recognition input uses per-student database lookups
- **Type/status:** Confirmed implementation pattern; deferred performance investigation.
- **Evidence:** `services/api/app/recognition_jobs.py:input_data` loops eligible roster members and fetches templates per member.
- **Proposal:** Benchmark realistic roster sizes before batching queries; preserve current consent/epoch checks if optimized later.
- **Reason deferred:** No demonstrated demo failure; backend changes are restricted to confirmed serious defects.

## External verification blockers

- Independent recognition acceptance remains 1/6; participants are unavailable. No accuracy/liveness/latency claims are added.
- Resend is unconfigured; email acceptance remains blocked while private downloads work.
- Physical Android UI/camera acceptance needs an available idle phone; builds alone do not establish device acceptance.
- Hosted lifecycle/destructive tests and authenticated visual walkthroughs require appropriate sessions and consenting data. Never fabricate results from fixtures.
- Continuous retention cannot be guaranteed while the Mac sleeps; existing reconciliation must be monitored.

## Prioritized implementation and acceptance

1. [x] Establish baseline and create this issue register before further changes.
2. [x] Fix FT-01/FT-04 responsive regressions; verify shared-core tests at 360/390/768/1440 px and 200% text.
3. [x] Fix FT-02/FT-03 and reduce FT-05 request waste with focused tests, including background polling.
4. [x] Apply FT-06 consistently across shared, Student and Teacher task screens without route or permission changes.
5. [x] Run Flutter analysis/core/capture/app suites and configured web/Android builds. Inspect the available Student session; record remaining visual gaps.
6. [x] Review staged paths, update checkpoints, commit and push without force (`7a36913`, verified on `origin/main`).

## Final verification

The first audit pass was committed and pushed at `7a36913`. External visual/device checks remain. Backend baseline **41/41** and worker baseline **5/5** passed; neither codebase changed. Flutter analysis found no issues in shared core, capture, Student or Teacher. Tests passed: shared core **20/20**, capture **7/7**, Student **4/4**, Teacher **8/8**. Both configured release web builds and both Android debug APKs built successfully. The existing Student web session was read-only inspected at phone width: approved class and published-history pages loaded with accessible actions and no visible clipping. That running 5301 instance predates the new release bundles; it does not establish visual acceptance of every changed authenticated screen.

The responsive regression checks cover 360, 390, 768 and 1440 px with enlarged text; they are synthetic layout checks, not a physical-device claim. The Teacher and Student authenticated release bundles were not visually inspected at every breakpoint, and the phone was not reinstalled during this review. Participant-dependent biometric, recognition, destructive lifecycle and email checks remain deferred. Frozen ML code, profiles, templates and root lock were untouched. `git diff --check` passed.


## Follow-up frontend review — 24 October 2026

This pass is limited to Flutter Student, Teacher and shared web/Android UI. No backend, schema, worker, camera or ML code changed. The worktree began clean at `7a36913`; `docs/CLIENT_PROJECT_DOCUMENT.md` appeared as an unrelated untracked file and is preserved outside this delivery.

| ID | Severity / evidence | Resolution and verification |
|---|---|---|
| FT-08 | **Medium, confirmed source risk:** resource detail routes reused unkeyed state across class/session IDs. `ProductApp` detail builders and stateful Student history/Teacher class/session screens lacked resource keys. | Key class and session subtrees by ID. A navigation regression confirms a class ID switch creates new screen state. |
| FT-09 | **High, confirmed source risk:** Student enrolment reconciled and could clear private pending media from an older API response before checking refresh generation. | Reject stale responses before pending-clip reconciliation, with checks after storage reads. An overlapping-refresh regression keeps the current synthetic private clip intact. A concurrent storage write during a clear remains a separate lifecycle hardening case. |
| FT-10 | **Medium, confirmed usability loss:** leaving Teacher session with edited, unsaved decisions silently discarded them. Explicit refresh also discarded choices. | GoRouter session exit asks Stay or Discard; explicit Refresh asks the same. Navigation test verifies Stay preserves the screen and Discard exits. Saving remains explicit. |
| FT-11 | **Medium, confirmed request waste:** the capture-status `FutureBuilder` created a new GET future on unrelated screen rebuilds. | Cache by capture ID and invalidate after load/upload. Synthetic request-count test verifies one GET across unrelated rebuilds. |
| FT-12 | **Low, confirmed request waste:** timetable validation poll loop could issue another GET after its screen was disposed. | Generation/disposal guard stops further requests. Widget regression confirms no second GET after disposal. |
| FT-13 | **Medium, reproduced accessibility defect:** Teacher attendance dropdown overflowed 102 px at 360 px and 72 px at 390 px with 200% text. | Expand the dropdown within its field and constrain labels. Authenticated session matrix now passes at 360/390/768/1440 px with 200% text. |
| FT-14 | **Low, design improvement:** Student upload errors could appear twice; session list actions and timetable instructions obscured the next step. | Keep upload error by the upload button, distinguish expired recording from retryable upload, label session actions by state, and show concise timetable steps/date/result. |

**Follow-up checks:** all four Flutter analyzers reported no issues. Complete suites passed: shared/core **22**, capture **7**, Student **9**, Teacher **14**. Configured Student and Teacher release web builds and Android debug APKs passed. Responsive Student active-enrolment and Teacher attendance-review tests passed at 360/390/768/1440 px with 200% text. No backend or worker source changed, so their previously passing suites were not repeated.

**Still pending:** newly built authenticated release screens were not visually inspected with a live Teacher session, and the physical phone was not reinstalled during this pass. The existing Student web tab is an older running preview, so it cannot verify the latest bundle. Recognition acceptance, participant-dependent tests, Resend delivery and cloud deployment are separate milestones.

## Non-ML demo closure review — 25 October 2026

This pass reviews the complete non-ML demo surface before the 28 October presentation. Frozen inference code, model artifacts, profiles and recognition thresholds are out of scope until the separate ML session. Baseline checks passed before further edits: backend **41**, worker **5**, shared core **22**, capture **7**, Student **9** and Teacher **14** tests; Ruff and all four Flutter analyzers were clean. The repository-managed PostgreSQL service was restored without touching hosted data.

| ID | Severity / evidence | Planned resolution and completion check |
|---|---|---|
| FT-15 | **High, confirmed race; fixed:** `TeacherSessionDetail.load` allowed timer, resume, refresh and post-mutation loads to overlap, so an older response could replace a newer authoritative version. | A resource generation guard rejects stale results and errors. A deliberately reversed-response regression passes. |
| FT-16 | **Medium, confirmed request leak; fixed:** terminal capture results were not reconciled into local state, so a closed session could continue polling after processing completed. | Capture status now updates local state and terminal closed-session polling stops. Request-count regression passes. |
| FT-17 | **Medium, confirmed lifecycle race; fixed:** pending-media read/save/retain/clear operations could interleave with logout, cleanup or upload checkpoints. | Operations now use one FIFO critical section. Late checkpoints update only the same still-current recording and cannot resurrect cleared metadata. Capture and complete Student suites pass. |
| FT-18 | **Low, confirmed UX issue; fixed:** full institute labels consumed narrow app-bar space; generic failures used the same connection icon and recovery copy. | Wide layouts show a styled institute label; narrow/large-text layouts expose a compact semantic badge. Authentication, authorization, missing-resource, rate-limit, service and Mac-connection errors now have distinct icon/title/action context. |
| FT-19 | **Medium, confirmed security consistency defect; fixed:** the middleware's early oversized-body 413 return bypassed standard response headers and request logging. | All middleware exits now apply request ID, `no-store`, `nosniff`, frame denial, no-referrer and restrictive permissions headers. A 1 MiB boundary regression passes. |
| FT-20 | **Low, confirmed presentation inconsistency; fixed:** Teacher web still used the old local camera spike title/description. | Student/Teacher source shells now use product-specific metadata and the shared theme color; configured release web builds pass. |
| OPS-01 | **High, resolved during audit:** the isolated PostgreSQL regression service appeared unavailable because its stale Unix socket could not be used from the restricted test process, while the managed server was still listening on loopback. | Re-ran the repository-owned startup tool and the full backend suite outside the restricted socket boundary: **41 passed**. No cluster deletion, credential rotation or hosted change occurred. |

### Prioritized implementation checklist

1. [x] Fix FT-15 and FT-16 with focused Teacher regressions.
2. [x] Fix FT-17 without changing upload, Storage or biometric API contracts.
3. [x] Apply FT-18 in shared UI and verify narrow large-text behavior.
4. [x] Fix FT-19/FT-20 and run all non-ML analysis/tests and configured Student/Teacher web and Android builds.
5. [ ] Inspect the newly built authenticated screens with safe live sessions and verify the latest APKs on an idle phone. The available browser instance is an older build, so this remains an external acceptance step.
6. [x] Synchronize `MASTER_DESIGN.md`, `PROGRESS.md` and `ROADMAP.md`; leave ML acceptance, model training, Resend and cloud deployment open.

### Final non-ML verification

Ruff and all four Flutter analyzers are clean. Tests pass: API **41**, worker **5**, shared core **23**, capture **8**, Student **9** and Teacher **16**. Both configured release web bundles and both Android debug APKs build. Fresh Student mobile-width and Teacher desktop-width release login pages were visually inspected with correct branding, readable actions and no visible clipping. Responsive widget coverage includes 360/390/768/1440 px and 200% text; focused regressions cover reversed Teacher session responses, terminal capture polling, stale private-media checkpoints and the oversized-body middleware path. `git diff --check` passes.

No schema, public endpoint contract, worker behavior, frozen inference code, model artifact, recognition profile, active template or attendance publication changed. Physical-device acceptance of these latest APKs and authenticated visual inspection of these exact release bundles remain pending. Recognition validation, Resend delivery and cloud deployment are intentionally outside this non-ML pass.
