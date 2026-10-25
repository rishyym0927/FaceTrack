# FaceTrack project instructions

Applies to this directory and its descendants.

## Start or resume

- Read `MASTER_DESIGN.md` and `PROGRESS.md` before implementation.
- Read `ROADMAP.md` for milestone order; check items only after their outcomes are verified.
- Treat `MASTER_DESIGN.md` as the architecture and requirements authority; `PROGRESS.md` records actual execution state.
- Verify the checkpoint against current files, and inspect Git status/diffs if a repository exists.
- Continue the next unfinished authorized task; preserve existing and uncommitted work.
- Follow the user's latest explicit instructions if they supersede these files. Record agreed design changes in the master design.
- If facts are missing, inspect the workspace first. Ask only for decisions or access that genuinely block progress.

## Fixed scope and stack

- Target a stable demonstration by 28 October 2026; institute deployment is a later validated milestone.
- Keep Flutter/Dart for the student and teacher apps, including teacher Flutter web for the Mac camera.
- Keep Python/FastAPI, Supabase Auth/PostgreSQL/private Storage, OpenCV/FFmpeg, SCRFD/ArcFace-family ONNX models, Redis/Celery, pandas/openpyxl/ReportLab, Resend, Docker, Sentry and GitHub Actions.
- Demo inference may run on the existing Mac; Runpod is the planned cloud GPU destination. State the actual deployment mode honestly.
- Prefer free tiers and existing equipment. Do not purchase services or introduce paid infrastructure without user authorization.
- Build vertical slices in the master design's order. The user explicitly authorized backend foundations while remaining participant tests are on hold at 1/6 passed; do not require those recordings before continuing backend work.
- Preserve the active ML freeze receipt and pinned root environment/lock, inference/evaluator source, profile and templates. Backend dependencies belong only in `services/api/.venv`, `services/api/pyproject.toml` and `services/api/uv.lock`.
- Run backend checks from `services/api` using `.venv/bin/python -m pytest tests -q`; from the root, specify `services/api/tests` explicitly. Local backend tests use managed PostgreSQL and mocked Auth HTTP; never call that live Supabase acceptance.
- Read `services/api/README.md` for provisioning and live checks. Runtime DB role must be restricted and separate from migration/seed owner credentials. Never expose business schema through Supabase's Data API.
- Keep stable student/teacher identities, approved memberships, teacher-assigned offerings and code-based pending enrolments. Never grant roles or attendance eligibility from signup metadata or possession of a code.
- Defer optional features and speculative infrastructure; do not change stack or architecture silently.

## Current development boundary

- Phase 3A account/class flows are complete in separate Student/Teacher Android + web apps: the user explicitly confirmed both apps' session restoration/logout, invalid-code recovery, and Teacher web keyboard/screen-reader navigation. Phase 3B consent/private media/durable biometric enrolment is implemented but its recovery/lifecycle acceptance remains in progress. Admin interface is later and web-only. Public signup remains deferred. Sessions/attendance/publication/timetable/report slices are implemented with remaining real-world gates tracked separately. Keep API/Redis/Celery/CPU on Mac; private Storage uses the existing free Supabase project. Worker dependencies belong in a separate worker environment/lock, never the frozen root environment.
- Preserve camera spike as `main_spike.dart`; product Teacher/Student ports are 5300/5301 and spike 5302. Keep app session stores isolated and infer permissions from API memberships/profiles.
- Use the user's physical Android phone; verify USB authorization and restore reverse port forwarding after reconnects with `scripts/android-connect`. Do not claim physical-device acceptance from an APK build. Keep native cleartext development-only and frontend config public-only.
- Windows development uses native Flutter plus `compose.windows.yaml` Linux services. Follow `docs/WINDOWS_SETUP.md`; do not attempt native Windows Celery/Redis or claim Windows acceptance until it is exercised on a real Windows host.

## Implementation safeguards

- Verify exact model files, preprocessing, runtime compatibility and permitted use; do not assume public weights allow institute deployment.
- Use real inference for demonstrations; mocks belong in clearly identified tests.
- Enforce tenant and object authorization, private media, consent and template revocation from the first working slice.
- Never commit secrets, raw student media or face templates. Do not reuse credentials embedded in reference documents.
- Missing recognition or processing failure leaves attendance unassessed; teachers review and publish authoritative results.
- Preserve idempotent job effects, immutable publication revisions and manual corrections.
- Measure accuracy and latency before claiming targets. Architecture alone does not establish production readiness.
- Run focused, meaningful checks for each change; record failures and checks not run explicitly.

## Checkpoint maintenance

- Update `PROGRESS.md` after each meaningful milestone and before a handoff or user-requested compaction.
- Update `ROADMAP.md` when a milestone is verified or its current-step marker changes; keep detailed execution notes in `PROGRESS.md`.
- Record completed work, unfinished changes, relevant files, commands/check results, blockers and the exact next action.
- Distinguish implemented, verified, planned and externally blocked items. Never mark planned work as complete.
- Keep the checkpoint concise and current; replace stale status rather than append a conversation transcript.
- Keep design decisions in `MASTER_DESIGN.md`; do not create competing HLD/LLD or alternate master documents.
- Do not record credentials, access tokens, biometric material or unnecessary personal data in checkpoints.

## Milestone 3B resume details

- Current development DB head is `0006_timetable_reports`, 36 forced-RLS tables. Both private Storage buckets and local Redis/Celery/agent are provisioned; the existing worker token was preserved while scoped capabilities expanded. Do not regenerate worker credentials on routine startup. Read service READMEs for commands.
- Integrated enrolment remains in real-device acceptance. Supabase object info can return top-level `content_type` with `metadata: null`; preserve regression coverage and do not bypass MIME validation. An expired 15-minute reservation requires a fresh recording.
- Do not reinstall/restart the phone app while the user is recording. Preserve pending private files on recoverable failures; never accept consent or approve identity/poses on their behalf.

## Approved demo completion

Keep the demo USB-connected and all API/Redis/Celery/CPU on Mac. HTTPS API deployment is after the demo. Implement small UI improvements, sessions/recognition, human publication/history, CSV timetable/reports/permitted email and rehearsal in that order. Do not treat the accepted enrolment happy path as full 3B acceptance or alter frozen matching settings.
The first real low-light two-person classroom capture processed with one corroborated recognition suggestion; the teacher confirmed both students Present and published revision 1. Final CSV/PDF downloads, student own history, and Teacher Android published-session view were user-confirmed. A live timetable import created one scheduled Monday session without duplicate keys. A better-lit two-person capture, absent/unknown/poor-media cases, lifecycle/recovery checks and rehearsal remain. Two consenting class members have active templates. User has no Resend account yet: keep private downloads working and email disabled. Do not interrupt recording with app reinstall/restart or publish attendance without human review.
