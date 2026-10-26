# FaceTrack platform support

FaceTrack does not currently support every operating system. This matrix describes code that exists and acceptance that has actually occurred.

| Platform | Status | How it runs | Important limits |
|---|---|---|---|
| macOS on Apple Silicon | Verified demo host | Flutter web in Chrome; FastAPI, Redis and Celery run locally | Keep the computer awake; Android uses USB forwarding. |
| Windows 10/11 x64 | Implemented; physical-host acceptance pending | Flutter web in Chrome/Edge; backend and worker run in Docker Desktop Linux containers | Requires WSL 2, virtualization, Docker Desktop and Flutter. Windows ARM is unverified. Both service images build and Compose validates, but a real Windows run has not yet happened. |
| Model Test Console (macOS/Windows) | Implemented; real-camera and Windows acceptance pending | Local page on 127.0.0.1:8010, Docker profile `console` on Windows | ML model only; needs the private model files and built page. See `MODEL_TEST_CONSOLE.md`. |
| Android arm64 | Verified development target | Separate Student and Teacher Flutter APKs | Local API requires USB forwarding; release signing/cloud API are later. |
| Browser web | Implemented | Student on port 5301 and Teacher on 5300 | Chrome is verified on macOS. Chrome/Edge are configured on Windows. Safari and Firefox camera flows are unverified. |
| Linux x64 or ARM host | Implemented (Docker); host-run acceptance pending | `scripts/setup.sh` + `docker compose up` for services; native Flutter web in a browser | Compose validates and both images build on the verified Mac; a full Linux host run is not recorded. Flutter is required because product web bundles are not committed/served. See `docs/LINUX_SETUP.md`. |
| iPhone/iPad (iOS/iPadOS) | Not supported | No iOS Flutter runner exists in either app | Requires iOS project generation, permissions, signing and device testing. |
| Native Windows desktop app | Not supported | Windows uses the web apps in Chrome/Edge | No `windows/` Flutter runner exists. |
| Native macOS desktop app | Not supported | macOS uses the web apps in Chrome | No `macos/` Flutter runner exists. |
| Native Linux desktop app | Not supported | No native Linux client | No `linux/` Flutter runner exists. |
| ChromeOS or other browsers | Unverified | Web may load, but camera, recording and storage behavior are not accepted | Treat as unsupported until tested. |

## Supported presentation combinations

Use one of these:

1. **Verified:** macOS host + Chrome Teacher/Student web + optional Android phone.
2. **Prepared for acceptance:** Windows 10/11 x64 host + Docker Desktop + Chrome/Edge Teacher/Student web + optional Android phone.
3. **Prepared for acceptance:** Linux x64/ARM host + Docker Engine + Chrome/Firefox Teacher/Student web.

All combinations still use the hosted Supabase development project and the separately supplied private configuration/model package. None is an institute production deployment.

The canonical cross-platform installation and configuration reference is [`docs/INSTALLATION.md`](INSTALLATION.md). A public clone alone can run synthetic tests, but cannot run real inference.

The backend runs from one canonical, cross-platform `compose.yaml` on every OS (`compose.windows.yaml` is a thin alias kept for the existing Windows scripts). Convenience verbs are the same everywhere: `make up|down|logs|console` on macOS/Linux, `.\run.ps1 up|down|logs|console` on Windows. "Prepared for acceptance" means the packaging and config validate, but a full host run on that OS has not yet been recorded in `PROGRESS.md`.

## Before claiming another platform

Add its Flutter runner or host scripts, verify camera permission and codec behavior, run authentication/session/upload/worker/report tests, test private-file cleanup, and record the physical-device result in `PROGRESS.md`. A dependency appearing in `pubspec.lock` does not establish application support.
