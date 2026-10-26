# FaceTrack — Build Checklist

**Target:** Working demonstration by 28 October 2026.
**Current step:** Demo code through timetable/report downloads is implemented and locally verified; development schema/bucket/worker are provisioned. Phase 3A account/class acceptance is complete. Two approved, consented class members have active templates. A real low-light classroom capture was teacher-reviewed and published; reports, own history and a Monday timetable import were verified. Migration 0007 is applied to the hosted development database; evidence-coded attendance drafts and student attendance queries are implemented and locally tested. Safe authenticated device acceptance remains. Next: preserve demo stability, run the isolated dataset baseline when licensed data is available, complete lifecycle/recovery and rehearse. API/worker remain on Mac; independent real recognition remains 1/6.

**Current enhancement:** Local live pose guidance is coded; the user confirmed Chrome guidance plus Android upright preview, matching left/right prompts and upright playback. Full five-pose, edge-case and live upload/review acceptance remains. Guidance is advisory and does not close milestone 3B or recognition acceptance.
**ML audit (25 October):** Freeze receipt remains 16/16; root synthetic/contract checks are 34 passed and 1 expected failure for degenerate alignment; worker checks are 5 passed. The beginner quickstart and aggregate held-out/matcher tools are available. Independent recognition remains 1/6; synthetic benchmarks do not close milestone 1 or establish institute capacity. Next ML gate is five new consenting Test clips, or a separately versioned alignment fix without changing the frozen baseline.
**Presentation audit checkpoint:** The issue register is `docs/APPLICATION_REVIEW.md`. Responsive sign-in/header fixes, Student history race protection, Teacher report refresh/polling fixes and the unified visual polish are implemented. Shared/capture/Student/Teacher tests pass **20/7/4/8**; all four analyses, both configured web builds and both debug APK builds pass. Existing Student web class/history screens were read-only inspected; newly built authenticated screens and physical-phone visual acceptance remain open. This checkpoint does not close milestones 3B–7.
**Frontend follow-up:** Resource navigation, saved-recording refresh safety, unsaved Teacher decision warning, bounded capture/timetable requests and narrow large-text attendance controls are implemented. All four analyses and **22/7/9/14** shared/capture/Student/Teacher tests pass; both configured web and Android builds pass. The existing milestone gates remain unchanged; newly built authenticated release visual/device checks are still open.
**Non-ML closure (25 October):** Session and pending-media races, terminal polling, narrow app-bar semantics, state-specific recovery views, web product metadata and universal API response headers are fixed. Ruff and all Flutter analyzers are clean; API/worker/shared/capture/Student/Teacher suites pass **41/5/23/8/9/16** and both web/APK build pairs pass. Remaining pre-demo work is safe authenticated visual/device inspection and rehearsal; Resend, ML validation and cloud deployment remain separate open gates.
**Windows portability (25 October):** Native Flutter plus Docker Desktop Linux services are implemented with PowerShell setup/start/stop/Android helpers and a dedicated beginner guide. Service-host validation remains restrictive and the macOS path is preserved. Static/script tests and existing macOS suites must pass; complete Windows host acceptance remains open and does not replace the verified Mac demo.
**Client/ML accuracy work (26 October):** The client response is complete and the repository plan is `docs/ML_ACCURACY_AND_ATTENDANCE_PLAN.md`. The receipt-pinned product baseline remains unchanged. A separate research package implements detector-only CLAHE, two-scale SCRFD, contrast/yaw candidates, safe per-crop alignment rejection, deterministic pseudonymous DigiFace manifests and aggregate-only outputs. The DigiFace synthetic benchmark has been run (baseline 0 wrong-present marks, 22/60 present students suggested; two-scale 24/60; CLAHE no change; contrast filter worse), labelled synthetic and not classroom accuracy. WIDER/BIWI and alternate detector cells remain **Not measured yet**. A client-run Model Test Console (`docs/MODEL_TEST_CONSOLE.md`) now exists for real-volunteer testing; Windows and real-camera acceptance are pending.

The user authorized backend work in parallel with the remaining ML tests. Check a milestone only after its acceptance passes. Technical decisions stay in `MASTER_DESIGN.md`; exact verified state is in `PROGRESS.md`.

## Demonstration milestones

- [ ] **1. Setup + ML proof of concept** — Verify tools, model permissions and Mac camera; recognize a few consenting people from real video and record timings.

  Setup, capture, model provisioning, reference-quality processing and evaluation tooling are implemented. Keep this milestone unchecked until calibrated multi-person recognition passes independent real recordings. Remaining clips are on hold until participants are available. Synthetic fixtures and single-person reference extraction do not complete it.
- [x] **2. Backend foundation** — FastAPI, Supabase, approved student/teacher identities, academic models, code requests and approval.

  Verified: 14 tables, restricted runtime role, tenant RLS, identity linkage, offering permissions, encrypted join codes, idempotency, rate limits and 21 PostgreSQL-backed tests. Real Supabase login, confirmed-email claim, access denials and teacher approval passed. Deployment mode is local API + hosted Auth/database; cloud API deployment remains a separate task.
- [x] **3A. Flutter account/class flows** — Separate Android/web apps, shared auth/theme, identity linkage, classes/codes, requests and approval/rosters. Both apps and request → approval → refreshed status are user-confirmed working; phone USB recovery passed. Student and Teacher session restoration/logout, invalid-code recovery and Teacher web keyboard/screen-reader navigation were explicitly confirmed on 23 October.
- [ ] **3B. Student biometric enrolment (in progress)** — Existing demo accounts, consent + guided face video → private free Supabase Storage → durable local worker → encrypted templates → supervised activation. Public signup/email configuration remains later.
- [ ] **4. Teacher attendance** — Session/frozen roster/private capture and local recognition are built and covered by synthetic regression tests. One real low-light two-person capture processed with only one corroborated suggestion; await better-lit two-person, unknown and absent cases.
- [ ] **5. Review + student history** — Manual review, immutable publication/correction and own history are built. Evidence-coded proposals and the student attendance-query/teacher-resolution path pass local authorization, idempotency and corrected-publication tests. The first real teacher publication is verified at revision 1, and user-confirmed own history appears. Await safe device acceptance and remaining negative permission checks before closing.
- [ ] **6. Timetable + reports** — Real hosted CSV preview/confirmation created a Monday session; user confirmed final CSV/PDF downloads and the correct class/session details and both Present rows. The UI now chooses a matching date and the API rejects zero-occurrence dates. Repeated import created one series and one dated session with no duplicate keys. Email delivery remains unverified because no permitted Resend sender is available; keep this milestone open for delivery.
- [ ] **7. Integration + demo readiness** — Verify USB-connected Mac API/local worker operation, Android builds and teacher web; test permissions, retries and worker restart; rehearse the complete flow.

## Suggested pace

| Date | Focus |
|---|---|
| 22 October | Milestone 1 |
| 23 October | Milestone 2 |
| 24 October | Milestone 3 |
| 25 October | Milestone 4 |
| 26 October | Milestones 5–6 |
| 27 October | Milestone 7; freeze features and rehearse |
| 28 October | Demonstration and blocker fixes |

This is an aggressive target, not a completion guarantee. Resolve camera/model blockers first; keep optional features out of the demo.

## After the demonstration

- [ ] **HTTPS API deployment** — Remove the USB dependency after the demonstration.
- [ ] **Supervised classroom pilot** — Test real rooms, capture quality, accuracy and privacy controls.
- [ ] **Full timetable automation** — Scheduled opening/closing, holidays, replacements and restart reconciliation.
- [ ] **Institute rollout** — Fund always-on hosting, move workers to approved cloud capacity, verify backups and benchmark 20 concurrent classes.

**Working rule:** Keep the agreed stack, use real inference, never turn processing failure into absence, and update this checklist plus `PROGRESS.md` after each verified milestone.
