# Run FaceTrack on Linux

This page is the Linux checklist. The complete configuration and first-time Supabase instructions are in [INSTALLATION.md](INSTALLATION.md).

**Status:** the canonical Linux-container stack validates and its API/worker images build on the verified Mac. A full physical Linux-host run is still pending.

## 1. Install once

Install Git, Docker Engine with the Compose v2 plugin, Flutter stable compatible with Dart 3.13.5, and Chrome. Use your distribution's current official installation instructions. Verify:

```sh
git --version
docker compose version
docker info
flutter --version
flutter doctor
flutter devices
```

Compose v2.20 or newer is required by the compatibility alias. Flutter is required because this repository does not commit or serve prebuilt Student/Teacher web bundles.

If Docker requires the `docker` group, complete the group change and log out/in before continuing.

## 2. Clone and prepare

```sh
git clone https://github.com/rishyym0927/FaceTrack.git
cd FaceTrack
scripts/setup.sh --skip-build
```

The setup script creates ignored config templates when missing and installs locked Flutter packages. Remove `--skip-build` to build Docker images immediately.

## 3. Add private configuration

Install the authorized private package at the exact paths listed in [INSTALLATION.md](INSTALLATION.md#4-fastest-setup-with-an-existing-private-package). A public clone has no credentials or model weights. For a new project, follow the owner setup in that guide.

## 4. Start the backend and apps

```sh
docker compose up -d --build
curl -fsS http://127.0.0.1:8000/health/ready
```

Expected response: `{"status":"ready"}`.

Start Teacher and Student in separate terminals:

```sh
cd apps/teacher
../../scripts/flutter run -d chrome --web-hostname localhost --web-port 5300 --dart-define-from-file=../../.local/flutter/development.json
```

```sh
cd apps/student
../../scripts/flutter run -d chrome --web-hostname localhost --web-port 5301 --dart-define-from-file=../../.local/flutter/development.json
```

Convenience commands:

```sh
make ps
make health
make logs
make down
```

## 5. Optional model-test console

```sh
scripts/build-console
make console
make console-down
```

Open `http://127.0.0.1:8010`. See [MODEL_TEST_CONSOLE.md](MODEL_TEST_CONSOLE.md).

## 6. Acceptance checklist

Before marking Linux verified, record all of these in `PROGRESS.md`:

1. API and worker images build.
2. Redis, API, worker and agent stay running.
3. `/health/ready` returns ready.
4. Both web apps load and controlled accounts can sign in.
5. A safe capture reaches the worker and completes.
6. `docker compose down` stops the stack cleanly.

## Common fixes

- **Docker permission denied:** log out/in after joining the Docker group, or follow your distribution's rootless Docker guidance.
- **`include` unsupported:** update Compose or use `docker compose -f compose.yaml up -d`.
- **Chrome is not a Flutter device:** install Chrome, then rerun `flutter devices`; `web-server` may be used for an unverified browser.
- **API not ready:** inspect `docker compose logs --tail 100 api` and verify migration/configuration using the troubleshooting section in [INSTALLATION.md](INSTALLATION.md#10-troubleshooting).
- **Worker stops:** verify the private model/profile paths and worker credential without printing their contents.
