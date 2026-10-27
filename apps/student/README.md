# FaceTrack Student

Separate Flutter Android/web app. Students link their approved identity, join subjects with a faculty join code, enrol their face with consent, see their own published attendance and raise an attendance query. Both apps share authentication, API transport, theme and controls through `packages/app_core`; permissions come from the backend.

Verified state and open acceptance checks are tracked in [`PROGRESS.md`](../../PROGRESS.md).

Complete host setup and configuration: [installation guide](../../docs/INSTALLATION.md).

From this app directory, using the already configured ignored public-only file:

```sh
../../scripts/flutter pub get --enforce-lockfile
../../scripts/flutter run -d chrome --web-hostname localhost --web-port 5301 --dart-define-from-file=../../.local/flutter/development.json
../../scripts/flutter build web --dart-define-from-file=../../.local/flutter/development.json
../../scripts/flutter build apk --debug --target-platform android-arm64 --dart-define-from-file=../../.local/flutter/development.json
```

On Windows, use the global `flutter` command and backslash paths, or start the full application with `..\..\scripts\windows\start-demo.ps1` from PowerShell. See the [Windows guide](../../docs/WINDOWS_SETUP.md). The `scripts/flutter` shell wrapper is for macOS/Linux, not PowerShell.

The API must be running on local port 8000. Login reaches hosted Supabase, but subjects require this local API; internet access alone is insufficient in the current development setup. On macOS, authorize USB debugging and run `../../scripts/android-connect` after reconnecting the cable. On Windows, run `..\..\scripts\windows\android-connect.ps1`. App ID: `dev.facetrack.student`. Use `flutter devices` and the same public configuration for interactive development.

Debug network policy permits HTTP only to localhost/127.0.0.1. Release requires HTTPS and your release signing configuration. Android Studio/emulator and iOS are not required for this slice.

See root `MASTER_DESIGN.md` for scope, the [installation guide](../../docs/INSTALLATION.md) for configuration, and `PROGRESS.md` for actual verification and remaining checks.

## Face enrolment

Open Enrolment, read the versioned notice and consent only voluntarily. Record alone using all five prompts, review playback, and select Upload for processing. The API, Redis, Celery and agent must be running on the local development computer; internet access is needed for private Storage. Keep USB connected while the API is local. Native pending recordings remain in private app storage; web recordings are temporary and disappear when the page closes.

Upload progress and errors appear beside the upload button. Retry upload reuses the same attempt and completion key; do not discard a recoverable recording. The application reservation lasts 15 minutes. An expired attempt requires a fresh recording. Processing produces a review candidate, not active recognition permission. A faculty member must verify identity and poses. Withdraw consent to revoke templates and queue media deletion.

## Published attendance

Open an approved subject to view your own published session results and revision notes after the faculty member publishes them. Unpublished or unassessed sessions do not count as absence. A percentage is shown only when assessed sessions provide a denominator; no other student's attendance is accessible.

For the latest published **Absent** result, the student can raise one written attendance query and see its open/accepted/rejected state. The backend derives the student from the authenticated account; no student ID is accepted from the client. Acceptance creates a corrected immutable publication. Push/email notifications and evidence attachments are not implemented.
