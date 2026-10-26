# Run FaceTrack on Linux

The backend runs in Docker containers (the same `compose.yaml` used on Windows
and macOS). The Student and Teacher apps run as Flutter **web** in a browser.
Auth and the database are the hosted Supabase development project; video
processing runs in the local worker container.

Tested distributions: Ubuntu 22.04/24.04 x64 and ARM64. Other modern distros
with Docker Engine should work the same way.

> Status: the Linux packaging and Docker config are in place and validated, but
> a full host run has not yet been recorded in `PROGRESS.md`. Treat this as
> "prepared for acceptance" until you complete the verification at the bottom.

## 1. Install once

```bash
# Docker Engine + the compose plugin (Ubuntu/Debian)
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-plugin git
sudo usermod -aG docker "$USER"   # then log out and back in
docker compose version            # expect v2.20 or newer (needed for `include`)
```

Flutter is only needed if you want to build the Android APK or run the web apps
without Docker; for the standard browser demo you do not need it.

## 2. Get the project and private configuration

```bash
git clone https://github.com/rishyym0927/FaceTrack.git
cd FaceTrack
```

The repository never contains credentials, model weights, recordings or
templates. An authorized operator must place the private package exactly as in
`docs/CLIENT_WINDOWS_HANDOFF.md`:

```text
services/api/.env
services/worker/.env
.local/flutter/development.json
.local/spike/models/buffalo_sc/      # entire directory
.local/spike/profiles/frozen-phase1b-v1.json
```

`scripts/setup.sh` creates the two config files from the checked-in examples if
they are absent (fill in the real values afterwards):

```bash
scripts/setup.sh --skip-build    # copies example config + fetches Flutter deps
```

## 3. Start the backend

```bash
make up            # or: docker compose up -d
make health        # or: curl -s http://127.0.0.1:8000/health/ready
```

Expect `{"status":"ready"}`. Follow logs with `make logs`.

## 4. Open the apps

Run the Flutter web apps in a browser. With a system Flutter install:

```bash
cd apps/teacher && ../../scripts/flutter run -d web-server --web-port 5300 \
  --dart-define-from-file=../../.local/flutter/development.json
# in another terminal
cd apps/student && ../../scripts/flutter run -d web-server --web-port 5301 \
  --dart-define-from-file=../../.local/flutter/development.json
```

Then open `http://localhost:5300` (Teacher) and `http://localhost:5301`
(Student) in Chrome or Firefox. Sign in with the controlled demo accounts;
public signup is not configured.

## 5. Client model-test page (optional)

```bash
scripts/build-console     # builds .local/console-web (needs Flutter)
make console              # serves http://127.0.0.1:8010
make console-down         # stop; volunteer data is kept until deleted on the page
```

## 6. Stop

```bash
make down
```

## Verification checklist (to record acceptance)

Run these on the Linux host and note the result in `PROGRESS.md`:

1. `docker compose build` completes for `api` and `worker`.
2. `make up` → `make health` returns `{"status":"ready"}`.
3. Both web apps load, a controlled account signs in, and a session page opens.
4. A capture uploads and the worker processes it (check `make logs`).
5. `make down` stops everything cleanly.

## Common fixes

- **`permission denied` on the Docker socket:** you have not re-logged in after
  `usermod -aG docker`; log out and back in, or run with `sudo`.
- **`include` not recognized:** Docker Compose is older than v2.20. Update the
  compose plugin, or run with the canonical file directly: `docker compose -f compose.yaml up -d`.
- **API not ready:** confirm `services/api/.env` has real Supabase values and no
  `REPLACE_*` placeholders; check `docker compose logs api`.
