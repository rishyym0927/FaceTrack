# FaceTrack Teacher

Separate Flutter Android/web app for faculty (and admins). Faculty manage their assigned subjects: join codes, student requests, rosters, face-enrolment review, sessions, timetable import, attendance publication and reports. Both apps share authentication, API transport, theme and controls through `packages/app_core`; permissions come from the backend, never from which app is opened.

Verified state and open acceptance checks are tracked in [`PROGRESS.md`](../../PROGRESS.md).

## Faculty dashboard

The home screen (`lib/teacher_dashboard.dart`) shows faculty-published attendance across every assigned subject: an overall percentage, semester filter and semester-wise bars, sortable subject-wise statistics (tap to open the subject), a distribution chart, a needs-attention list of students below 75%, and **Export report** for a semester CSV. Percentages use assessed classes only; unassessed or excused classes never count as absence. It is computed in the app from each subject's `attendance-summary`.

## Administration

Accounts with an active admin membership also see the **Admin** tab (`lib/teacher_admin.dart`). **Overview** shows a setup checklist with the next step, statistics, charts and the institute-wide attendance dashboard. **1 · Academic setup** creates semester terms, subjects, sections and subject allocations. **2 · People** adds faculty and students and lists them. **3 · Access & assignments** assigns faculty to subjects and grants roles by picking a person. The server re-checks the admin role on every write.

Complete host setup and configuration: [installation guide](../../docs/INSTALLATION.md).

From this app directory, using the already configured ignored public-only file:

```sh
../../scripts/flutter pub get --enforce-lockfile
../../scripts/flutter run -d chrome --web-hostname localhost --web-port 5300 --dart-define-from-file=../../.local/flutter/development.json
../../scripts/flutter build web --dart-define-from-file=../../.local/flutter/development.json
../../scripts/flutter build apk --debug --target-platform android-arm64 --dart-define-from-file=../../.local/flutter/development.json
```

On Windows, use the global `flutter` command and backslash paths, or start the full application with `..\..\scripts\windows\start-demo.ps1` from PowerShell. See the [Windows guide](../../docs/WINDOWS_SETUP.md). The `scripts/flutter` shell wrapper is for macOS/Linux, not PowerShell.

The API must be running on local port 8000. Login reaches hosted Supabase, but subjects require this local API; internet access alone is insufficient in the current development setup. On macOS, authorize USB debugging and run `../../scripts/android-connect` after reconnecting the cable. On Windows, run `..\..\scripts\windows\android-connect.ps1`. App ID: `dev.facetrack.teacher`. Use `flutter devices` and the same public configuration for interactive development.

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

## Face enrolment review

In an assigned subject, open Face enrolments. Only actively enrolled students awaiting review appear. Open the short-lived private video, review identity and all five poses, then approve with both explicit confirmations or reject with a reason. Refresh after a stale-version conflict. Expired footage requires fresh enrolment. Approval activates encrypted templates; it does not create attendance. Do not approve a recording solely because processing succeeded.

## Sessions, timetable and reports

In an assigned subject, **Sessions** creates a manual session or expands **Import timetable**. Add any missing room code first. Download the exact 14-column template, fill assigned academic values, select a CSV under 1 MiB and inspect validated rows. The app suggests the next date matching a CSV weekday; confirm that date or pick another matching day inside the term. Confirmation materializes sessions **for that day only** while retaining the weekly rule for future dates; a nonmatching date is rejected. Opening and closing scheduled sessions remains manual. Re-imports preserve opened history and reject stale previews/overlaps.

Open a session to freeze the approved roster. Record a short classroom clip with only consenting participants, audio off, and upload it while the local API/worker run. Suggestions need human review; missed/unknown students remain unassessed. Close, save explicit decisions, acknowledge unassessed rows, then publish. A later correction requires a reason and creates a new immutable revision. Reports appear after closing/publication: download CSV or PDF using short-lived private grants. Email stays disabled until a permitted Resend sender is configured. Never mark a student absent merely because a capture failed.

The **Attendance queries** tab lists open queries for assigned offerings. Rejecting requires a reason. Accepting creates a new immutable corrected publication/report; it does not rewrite the earlier publication. Only the latest published Absent result can be queried by its own student.
