# FaceTrack — Build Checklist

**Target:** Working demonstration by 28 October 2026.
**Current step:** Demo code through timetable/report downloads is implemented and locally verified; development schema/bucket/worker are provisioned. Phase 3A account/class acceptance is complete. Two approved, consented class members have active templates. A real low-light classroom capture produced one recognition suggestion; the teacher confirmed both students Present and published revision 1. User confirmed final CSV/PDF downloads and own student history work. A real CSV import created one Monday scheduled session after the correct date was selected. Next: better-lit and negative recognition cases, 3B lifecycle/recovery and rehearsals. API/worker remain on Mac; cloud deployment is pending. Independent ML tests remain on hold at 1/6 passed.

The user authorized backend work in parallel with the remaining ML tests. Check a milestone only after its acceptance passes. Technical decisions stay in `MASTER_DESIGN.md`; exact verified state is in `PROGRESS.md`.

## Demonstration milestones

- [ ] **1. Setup + ML proof of concept** — Verify tools, model permissions and Mac camera; recognize a few consenting people from real video and record timings.

  Setup, capture, model provisioning, reference-quality processing and evaluation tooling are implemented. Keep this milestone unchecked until calibrated multi-person recognition passes independent real recordings. Remaining clips are on hold until participants are available. Synthetic fixtures and single-person reference extraction do not complete it.
- [x] **2. Backend foundation** — FastAPI, Supabase, approved student/teacher identities, academic models, code requests and approval.

  Verified: 14 tables, restricted runtime role, tenant RLS, identity linkage, offering permissions, encrypted join codes, idempotency, rate limits and 21 PostgreSQL-backed tests. Real Supabase login, confirmed-email claim, access denials and teacher approval passed. Deployment mode is local API + hosted Auth/database; cloud API deployment remains a separate task.
- [x] **3A. Flutter account/class flows** — Separate Android/web apps, shared auth/theme, identity linkage, classes/codes, requests and approval/rosters. Both apps and request → approval → refreshed status are user-confirmed working; phone USB recovery passed. Student and Teacher session restoration/logout, invalid-code recovery and Teacher web keyboard/screen-reader navigation were explicitly confirmed on 23 October.
- [ ] **3B. Student biometric enrolment (in progress)** — Existing demo accounts, consent + guided face video → private free Supabase Storage → durable local worker → encrypted templates → supervised activation. Public signup/email configuration remains later.
- [ ] **4. Teacher attendance** — Session/frozen roster/private capture and local recognition are built and covered by synthetic regression tests. One real low-light two-person capture processed with only one corroborated suggestion; await better-lit two-person, unknown and absent cases.
- [ ] **5. Review + student history** — Manual review, immutable publication/correction and own history are built. The first real teacher publication is verified at revision 1, and user-confirmed own history appears. Await correction/device and negative permission checks before closing.
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
