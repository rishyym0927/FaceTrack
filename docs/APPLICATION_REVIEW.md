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
6. [ ] Review staged paths, update checkpoints, commit and push without force.

## Final verification

Implementation and verification completed except Git delivery and external visual/device checks. Backend baseline **41/41** and worker baseline **5/5** passed; neither codebase changed. Flutter analysis found no issues in shared core, capture, Student or Teacher. Tests passed: shared core **20/20**, capture **7/7**, Student **4/4**, Teacher **8/8**. Both configured release web builds and both Android debug APKs built successfully. The existing Student web session was read-only inspected at phone width: approved class and published-history pages loaded with accessible actions and no visible clipping. That running 5301 instance predates the new release bundles; it does not establish visual acceptance of every changed authenticated screen.

The responsive regression checks cover 360, 390, 768 and 1440 px with enlarged text; they are synthetic layout checks, not a physical-device claim. The Teacher and Student authenticated release bundles were not visually inspected at every breakpoint, and the phone was not reinstalled during this review. Participant-dependent biometric, recognition, destructive lifecycle and email checks remain deferred. Frozen ML code, profiles, templates and root lock were untouched. `git diff --check` passed.
