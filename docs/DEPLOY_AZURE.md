# Online deployment on one Azure VM

FaceTrack runs online on a single Azure virtual machine. Data stays in the hosted Supabase project; the VM runs the API, Redis, the Celery worker and the agent in Docker, plus Caddy for HTTPS and the two web apps.

| What | Address |
|---|---|
| Teacher web | https://facetrack.centralindia.cloudapp.azure.com/teacher/ |
| Student web | https://facetrack.centralindia.cloudapp.azure.com/student/ |
| API (for the apps) | https://facetrack.centralindia.cloudapp.azure.com |
| Health | https://facetrack.centralindia.cloudapp.azure.com/health/ready |

## The server

- Azure for Students subscription, resource group `facetrack-rg`, VM `facetrack-vm`, Central India, `Standard_B2as_v2` (2 vCPU, 8 GB, burstable), Ubuntu 24.04, 64 GB Standard SSD, static public IP with DNS label `facetrack`. Check actual spend and credit in the Azure portal.
- Firewall: 80 and 443 open; SSH (22) only from the operator's IP. Port 8000 is never opened: the API listens on `127.0.0.1` and Caddy fronts it.
- Login: `ssh -i ~/.ssh/facetrack_azure azureuser@facetrack.centralindia.cloudapp.azure.com`. Use the operator's authorized SSH key.
- Layout: code in `/opt/facetrack` (from `git archive origin/main`), web builds served at `/srv/facetrack/{teacher,student}`, Caddy config in `/etc/caddy/Caddyfile` (copy of [deploy/azure/Caddyfile](../deploy/azure/Caddyfile)).
- Private files copied over SSH: `services/api/.env`, `services/worker/.env`, `.local/spike/models/buffalo_sc/` and `.local/spike/profiles/frozen-phase1b-v1.json`. On the server, `MIGRATION_DATABASE_URL` is removed from the API `.env` (the runtime never uses the owner credential) and `CORS_ORIGINS` includes the public origin.
- Caddy blocks `/internal/*` (the agent reaches the API on the private Docker network) and the OpenAPI docs pages.

## One backend only

The VM's agent claims processing jobs from the shared hosted database. Run **either** the VM worker/agent **or** a local one, never both. Local apps and the local API can keep running: jobs they create are processed by the VM.

- Move processing back to a Mac: `ssh … 'cd /opt/facetrack && docker compose stop worker agent'`, then start the local worker and agent.
- Move it to the VM again: stop the local worker and agent, then `docker compose up -d worker agent` on the VM.

## Updating

From the Mac, after pushing to `main` (the script starts the VM if it is deallocated and allows SSH from your current IP first):

```sh
deploy/azure/deploy.sh            # ships origin/main, rebuilds containers and both web apps
deploy/azure/deploy.sh --web-only # only the web apps
```

Use a full deploy when a change affects the API or worker. Both web builds transfer into a new release directory before the shared `web-current` pointer changes. The first run converts the existing app directories into
symlinks while preserving their content. The script checks the public HTML and
JavaScript for both apps and restores the previous pointer on failure. A full
deploy also restores the previous service tree if the web checks fail. Keep
`/srv/facetrack` writable by the deploy user and retain the previous release
directory for recovery.

The deploy reads `.local/flutter/production.json` with the same four public values as [development configuration](INSTALLATION.md#55-configure-flutter) and the public HTTPS API origin. It deploys the remote `main` revision and carries forward private environment and model files. Apply any required schema change separately before deploying code that needs it.

After the script succeeds, verify the public endpoints and check container state:

```sh
base=https://facetrack.centralindia.cloudapp.azure.com
curl -fsS "$base/health/ready"
curl -fsS -o /dev/null "$base/student/"
curl -fsS -o /dev/null "$base/teacher/"
```

The readiness response should be `{"status":"ready"}`. Verify authenticated sign-in and classroom recording separately using controlled accounts. Public smoke checks cover served files and service readiness.

## Phone apps (release build)

Release APKs are signed with the key in `.local/release/signing/` (`facetrack-release.jks` and `key.properties`, both git-ignored). **Back up both files somewhere private**: an app signed with a different key cannot update an installed one. From a clean worktree of `origin/main`:

```sh
export FACETRACK_KEY_PROPERTIES="$PWD/.local/release/signing/key.properties"
for app in student teacher; do
  (
    cd "apps/$app" || exit 1
    ../../scripts/flutter build apk --release --target-platform android-arm64 \
      --dart-define-from-file=../../.local/flutter/production.json
  ) || exit 1
done
```

Each app writes `build/app/outputs/flutter-apk/app-release.apk` inside its directory. Verify both APK signatures using Android SDK Build Tools’ `apksigner verify`. An existing debug build uses a different signing key. Finish pending uploads before uninstalling it to install the release build.

Before distributing an APK that changes camera capture, Flutter or CameraX, ML Kit, or Android packaging, run the signed Android camera check for [Student](CAMERA_VALIDATION.md#student-android-signed-release-check) or [Teacher](CAMERA_VALIDATION.md#teacher-android-signed-release-check), as affected. Earlier releases passed Flutter tests but lost ML Kit initialization under R8 and rotated the preview only when native recording started. A debug build cannot cover the release optimizer.

## Day-to-day

```sh
ssh -i ~/.ssh/facetrack_azure azureuser@facetrack.centralindia.cloudapp.azure.com
cd /opt/facetrack
docker compose ps                              # api, redis, worker, agent should be running
docker compose logs --tail 100 api worker agent
```

- Containers restart automatically after a reboot.
- Pause billing: `az vm deallocate -g facetrack-rg -n facetrack-vm`; resume: `az vm start -g facetrack-rg -n facetrack-vm` (the IP and name stay).
- SSH refused after the operator's IP changes: `az network nsg rule update -g facetrack-rg --nsg-name facetrack-vmNSG -n default-allow-ssh --source-address-prefixes <new-ip>/32`.
- The worker credential is time-limited. An expired or rejected credential pauses processing while uploads wait in the queue. Contact the operator for credential replacement. After updating the private worker configuration, recreate the worker and agent with `docker compose up -d --force-recreate worker agent` and check the agent logs.
- "Enrolment agent waiting for local API/broker" means the agent cannot reach the API or Redis (network or startup), not a credential problem.

## Limits to state honestly

- B-series VMs are burstable: long recognition jobs can slow down once CPU credits run out.
- The InsightFace model permission covers the non-commercial academic demonstration only.
- The phone app still points wherever its APK was built for; a phone build against this server needs `--dart-define-from-file=.local/flutter/production.json`.
