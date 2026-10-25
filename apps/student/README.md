# FaceTrack Student

Separate Flutter Android/web app. Link an approved identity, enter a teacher join code, and see your own class requests/statuses. Both apps share authentication, API transport, theme and controls through `packages/app_core`; permissions come from the backend. Controlled confirmed demo accounts only in this slice.

**Status — 23 October 2026:** account/class acceptance is complete. Student restart/logout and invalid-code recovery were explicitly confirmed, as were Teacher web keyboard/screen-reader controls. Real biometric happy paths are user-confirmed. After a real teacher publication, the user confirmed their own published attendance appears in Student history. Android history and 3B lifecycle/recovery checks remain open.

From this app directory, using the already configured ignored public-only file:

```sh
../../scripts/flutter pub get --enforce-lockfile
../../scripts/flutter run -d chrome --web-hostname localhost --web-port 5301 --dart-define-from-file=../../.local/flutter/development.json
../../scripts/flutter build web --dart-define-from-file=../../.local/flutter/development.json
../../scripts/flutter build apk --debug --target-platform android-arm64 --dart-define-from-file=../../.local/flutter/development.json
```

On Windows, use the global `flutter` command and backslash paths, or start the full application with `..\..\scripts\windows\start-demo.ps1` from PowerShell. See the [Windows guide](../../docs/WINDOWS_SETUP.md). Do not use the macOS-only `scripts/flutter` wrapper on Windows.

The API must be running on local port 8000. Login reaches hosted Supabase, but classes require this local API; internet access alone is insufficient in the current development setup. On macOS, authorize USB debugging and run `../../scripts/android-connect` after reconnecting the cable. On Windows, run `..\..\scripts\windows\android-connect.ps1`. App ID: `dev.facetrack.student`. Use `flutter devices` and the same public configuration for interactive development.

Debug network policy permits HTTP only to localhost/127.0.0.1. Release requires HTTPS and your release signing configuration. Android Studio/emulator and iOS are not required for this slice.

See root `MASTER_DESIGN.md` for scope, `README.md` for public configuration fields and `PROGRESS.md` for actual verification and remaining checks.

## Face enrolment (Milestone 3B, acceptance in progress)

Open Enrolment, read the versioned notice and consent only voluntarily. Record alone using all five prompts, review playback, and select Upload for processing. The API, Redis, Celery and agent must be running on the local development computer; internet access is needed for private Storage. Keep USB connected while the API is local. Native pending recordings remain in private app storage; web recordings are temporary and disappear when the page closes.

Upload progress and errors appear beside the upload button. Retry upload reuses the same attempt and completion key; do not discard a recoverable recording. The application reservation lasts 15 minutes. An expired attempt requires a fresh recording. Processing produces a review candidate, not active recognition permission. A teacher must verify identity and poses. Withdraw consent to revoke templates and queue media deletion.

## Published attendance

Open an approved class to view your own published session results and revision notes after the teacher publishes. Unpublished or unassessed sessions do not count as absence. A percentage is shown only when assessed sessions provide a denominator; no other student's attendance is accessible. The first real publication/history flow is verified; broader negative and correction checks remain open.
