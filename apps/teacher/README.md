# FaceTrack Teacher

Separate Flutter Android/web app. Manage assigned attendance classes, join codes, student requests and approved rosters. Both apps share authentication, API transport, theme and controls through `packages/app_core`; permissions come from the backend. Controlled confirmed demo accounts only in this slice.

**Status — 26 October 2026:** account/class acceptance is complete, including native restart/logout and web keyboard/screen-reader checks. Real biometric review and one human-reviewed low-light classroom publication are verified; final reports, own student history and one Monday timetable occurrence are user-confirmed. Attendance-query review is implemented and locally tested; authenticated device acceptance and broader recognition/recovery checks remain open.

Complete host setup and configuration: [installation guide](../../docs/INSTALLATION.md).

From this app directory, using the already configured ignored public-only file:

```sh
../../scripts/flutter pub get --enforce-lockfile
../../scripts/flutter run -d chrome --web-hostname localhost --web-port 5300 --dart-define-from-file=../../.local/flutter/development.json
../../scripts/flutter build web --dart-define-from-file=../../.local/flutter/development.json
../../scripts/flutter build apk --debug --target-platform android-arm64 --dart-define-from-file=../../.local/flutter/development.json
```

On Windows, use the global `flutter` command and backslash paths, or start the full application with `..\..\scripts\windows\start-demo.ps1` from PowerShell. See the [Windows guide](../../docs/WINDOWS_SETUP.md). The `scripts/flutter` shell wrapper is for macOS/Linux, not PowerShell.

The API must be running on local port 8000. Login reaches hosted Supabase, but classes require this local API; internet access alone is insufficient in the current development setup. On macOS, authorize USB debugging and run `../../scripts/android-connect` after reconnecting the cable. On Windows, run `..\..\scripts\windows\android-connect.ps1`. App ID: `dev.facetrack.teacher`. Use `flutter devices` and the same public configuration for interactive development.

Debug network policy permits HTTP only to localhost/127.0.0.1. Release requires HTTPS and your release signing configuration. Android Studio/emulator and iOS are not required for this slice.

## Preserved local camera spike

Product login is the default entrypoint. The original capture implementation is retained in `lib/spike_app.dart` and launched separately:

```sh
../../scripts/flutter run -d chrome -t lib/main_spike.dart --web-hostname localhost --web-port 5302
../../scripts/flutter build web -t lib/main_spike.dart --output build/spike
../../scripts/flutter test
```

The spike saves local recordings/sidecars; the product Sessions tab has its own signed private classroom upload. Keep all existing consent, calibration/test separation and 24-hour raw-media rules.

See root `MASTER_DESIGN.md` for scope, the [installation guide](../../docs/INSTALLATION.md) for configuration, and `PROGRESS.md` for actual verification and remaining checks.

## Face enrolment review (Milestone 3B, acceptance in progress)

In an assigned class, open Face enrolments. Only actively enrolled students awaiting review appear. Open the short-lived private video, review identity and all five poses, then approve with both explicit confirmations or reject with a reason. Refresh after a stale-version conflict. Expired footage requires fresh enrolment. Approval activates encrypted templates; it does not create attendance. Do not approve a recording solely because processing succeeded.

## Sessions, timetable and reports (acceptance in progress)

In an assigned class, **Sessions** creates a manual session or expands **Import timetable**. Add any missing room code first. Download the exact 14-column template, fill assigned academic values, select a CSV under 1 MiB and inspect validated rows. The app suggests the next date matching a CSV weekday; confirm that date or pick another matching day inside the term. Confirmation materializes sessions **for that day only** while retaining the weekly rule for future dates; a nonmatching date is rejected. Opening/closing scheduled sessions remains manual. Re-imports preserve opened history and reject stale previews/overlaps.

Open a session to freeze the approved roster. Record a short classroom clip with only consenting participants, audio off, and upload it while the local API/worker run. Suggestions need human review; missed/unknown students remain unassessed. Close, save explicit decisions, acknowledge unassessed rows, then publish. A later correction requires a reason and creates a new immutable revision. Reports appear after closing/publication: download CSV or PDF using short-lived private grants. Email stays disabled until a permitted Resend sender is configured. Never mark a student absent merely because a capture failed.

The **Attendance queries** tab lists open queries for assigned offerings. Rejecting requires a reason. Accepting creates a new immutable corrected publication/report; it does not rewrite the earlier publication. Only the latest published Absent result can be queried by its own student.
