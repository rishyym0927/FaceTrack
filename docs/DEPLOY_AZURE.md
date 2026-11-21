# Online deployment on one Azure VM

FaceTrack runs online on a single Azure virtual machine. Data stays in the hosted Supabase project; the VM runs the API, Redis, the Celery worker and the agent in Docker, plus Caddy for HTTPS and the two web apps.

| What | Address |
|---|---|
| Teacher web | https://facetrack.centralindia.cloudapp.azure.com/teacher/ |
| Student web | https://facetrack.centralindia.cloudapp.azure.com/student/ |
| API (for the apps) | https://facetrack.centralindia.cloudapp.azure.com |
| Health | https://facetrack.centralindia.cloudapp.azure.com/health/ready |

## The server

- Azure for Students subscription, resource group `facetrack-rg`, VM `facetrack-vm`, Central India, `Standard_B4as_v2` (4 vCPU, 16 GB, burstable; resized from `Standard_B2as_v2` on 2026-11-21, about 72 USD/month at retail if running all month), Ubuntu 24.04, 64 GB Standard SSD, static public IP with DNS label `facetrack`. Check actual spend and credit in the Azure portal.
- Processing: two `worker` containers (Compose `deploy.replicas: 2`, solo pool each) fed by one `agent` with `WORKER_SLOTS=2`; the API lets one worker identity hold `WORKER_MAX_LEASES` (default 2) leases. All three numbers must agree, otherwise jobs silently run one at a time. Details under [Capacity and sizing](#capacity-and-sizing).
- Firewall: 80 and 443 open; SSH (22) only from the operator's IP. Port 8000 is never opened: the API listens on `127.0.0.1` and Caddy fronts it.
- Login: `ssh -i ~/.ssh/facetrack_azure azureuser@facetrack.centralindia.cloudapp.azure.com`. Use the operator's authorized SSH key.
- Layout: code in `/opt/facetrack` (from `git archive origin/main`), web builds served at `/srv/facetrack/{teacher,student}`, Caddy config in `/etc/caddy/Caddyfile` (copy of [deploy/azure/Caddyfile](../deploy/azure/Caddyfile)).
- Private files copied over SSH: `services/api/.env`, `services/worker/.env`, `.local/spike/models/buffalo_sc/` and `.local/spike/profiles/frozen-phase1b-v1.json`. On the server, `MIGRATION_DATABASE_URL` is removed from the API `.env` (the runtime never uses the owner credential) and `CORS_ORIGINS` includes the public origin.
- Caddy blocks `/internal/*` (the agent reaches the API on the private Docker network) and the OpenAPI docs pages.

## Worker ownership

A worker credential is scoped to **one institute** and a set of job types: the API hands a worker only jobs from its own institute. A credential for the wrong institute looks healthy (it polls, is told "nothing to do", logs no error) while every segment waits forever. Check this after any credential or compose change:

```sh
cd services/api && .venv/bin/python -m tools.check_worker   # read-only; exits 1 if queued work has no worker
```

**Current setup (from 21 November 2026).** The base Compose pair (`facetrack-worker-1`, `facetrack-agent-1`) serves the **Indira Gandhi Delhi Technical University for Women** institute, where all classes run. Its credential permits enrolment, recognition and reports and expires on 11 December 2026. The Demo institute no longer has a worker on the VM (its credential, which expired the next day, is no longer used).

Before that date the base pair held the Demo institute's credential while a separate pair, `facetrack-project-enrolment-agent` and `-worker` (Redis database 4, private config under `~/.facetrack-project-enrolment`), served the real institute. A routine tidy-up stopped that second pair as "stale", and the base pair, serving the wrong institute, never processed any class. The credential was moved into `services/worker/.env` (a backup of the previous file is in `~/.facetrack-backups`) and the second pair stays stopped with restarts disabled; remove it once you are sure it is not needed. Never run two agents with the same credential.

- Local apps and the local API can stay running against the shared database. Only one processing backend should serve a given institute at a time.
- To move processing to a Mac: stop the VM's `worker` and `agent`, then start the local pair with the same institute credential.

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

The deploy reads `.local/flutter/production.json` with the same four public values as [development configuration](INSTALLATION.md#55-configure-flutter) and the public HTTPS API origin. It deploys the remote `main` revision and carries forward private environment and model files. Apply any required schema change separately before deploying code that needs it. To roll back, set `FACETRACK_DEPLOY_REV` to the full SHA of a compatible revision already in `origin/main` history, then run the full deploy.

The academic edit rollout requires a bridge release that accepts both `0008_admin` and `0009_academic_edit`. Deploy and check the bridge first, take a private database backup, and use the owner connection to apply `0009_academic_edit`. Verify the API is still ready before deploying the editor. Roll back the application to the bridge if necessary. The additive migration can remain installed.

After the script succeeds, verify the public endpoints and check container state:

```sh
base=https://facetrack.centralindia.cloudapp.azure.com
curl -fsS "$base/health/ready"
curl -fsS -o /dev/null "$base/student/"
curl -fsS -o /dev/null "$base/teacher/"
```

The readiness response should be `{"status":"ready"}`. Verify authenticated sign-in and classroom recording separately using controlled accounts. Public smoke checks cover served files and service readiness.

## Phone apps (release build)

Release APKs are signed with the key in `.local/release/signing/` (`facetrack-release.jks` and `key.properties`, both git-ignored). **Back up both files somewhere private**: an app signed with a different key cannot update an installed one. Use a clean checkout of `origin/main` with the private signing files and production Flutter configuration prepared for that checkout. From the repository root:

```sh
export FACETRACK_KEY_PROPERTIES="$PWD/.local/release/signing/key.properties"
for app in student teacher; do
  (
    cd "apps/$app" || exit 1
    ../../scripts/flutter build apk --release --target-platform android-arm64 --split-per-abi \
      --dart-define-from-file=../../.local/flutter/production.json
  ) || exit 1
done
```

Each app writes `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk` inside its directory. Verify both APK signatures using Android SDK Build Tools’ `apksigner verify`. An existing debug build uses a different signing key. Finish pending uploads before uninstalling it to install the release build.

Before distributing an APK that changes camera capture, Flutter or CameraX, ML Kit, or Android packaging, run the signed Android camera check for [Student](CAMERA_VALIDATION.md#student-android-signed-release-check) or [Teacher](CAMERA_VALIDATION.md#teacher-android-signed-release-check), as affected. Earlier releases passed Flutter tests but lost ML Kit initialization under R8 and rotated the preview only when native recording started. A debug build cannot cover the release optimizer.

## Day-to-day

```sh
ssh -i ~/.ssh/facetrack_azure azureuser@facetrack.centralindia.cloudapp.azure.com
cd /opt/facetrack
docker compose ps                              # api, redis, worker, agent should be running
docker compose logs --tail 100 api worker agent
```

- Containers restart automatically after a reboot.
- Pause billing: `az vm deallocate -g facetrack-rg -n facetrack-vm`; resume: `az vm start -g facetrack-rg -n facetrack-vm` (the IP and name stay). A resize reset the burst-credit bank to its starting balance, and it is not known whether a deallocate does; before a demo, leave the VM running for a day so the bank refills.
- Container logs are deleted when the containers are recreated, which every deploy does. To keep the logs of a class, save them first: `scripts/logs --vm --since 24h <session-id>` or `ssh ... 'cd /opt/facetrack && sudo docker compose logs --no-log-prefix --since 24h api worker agent' > classes.log`.
- SSH refused after the operator's IP changes: `az network nsg rule update -g facetrack-rg --nsg-name facetrack-vmNSG -n default-allow-ssh --source-address-prefixes <new-ip>/32`.
- The worker credential is time-limited. An expired or rejected credential pauses processing while uploads wait in the queue. Contact the operator for credential replacement. After updating the private worker configuration, recreate the worker and agent with `docker compose up -d --force-recreate worker agent` and check the agent logs.
- "Enrolment agent waiting for local API/broker" means the agent cannot reach the API or Redis (network or startup), not a credential problem.

### Reports stay queued

Refresh the session first. On Azure, check the project agent and worker:

```sh
docker logs --tail 50 facetrack-project-enrolment-agent
docker logs --tail 50 facetrack-project-enrolment-worker
```

From the operator's authorized database console, verify an active, unexpired worker credential for the correct institute. Check that its permitted job types include `report` and that `last_seen_at` is recent. Check the report job and report record for `succeeded` and `ready`. After restoring the correct worker permission, let existing jobs run before requesting another report. See the [worker guide](../services/worker/README.md) for processing and credential details.

## Reading the logs

Every service writes **one JSON object per line**: `ts`, `service`, `event`, `level` where
relevant, and correlation ids. The API, the worker and the agent log to Docker (rotated: 5 files
of 10 MB each per service). The apps send anonymous diagnostics to `POST /v1/client-events`, which
the API writes to the same log as `client_event` lines.

**Trace a problem**

```sh
scripts/logs --vm <session-id>        # everything about one class: requests, jobs, app events
scripts/logs --vm <8+ chars of ref>   # the "Reference: ..." line shown under an error in the app
scripts/logs --vm --errors            # recent warnings and errors only
scripts/logs --vm --resources         # CPU, memory and disk readings (one per minute)
scripts/logs --vm --since 6h <id>     # look further back (default 1h)
```

Drop `--vm` on the VM itself or on a Mac running the Docker stack. Ids that work: an attendance
session id, a capture id, a job id, or the start of a request id.

| Event | Service | What it tells you |
|---|---|---|
| `request` | api | route template, status, error `code`, duration, DB wait, `session_id`/`capture_id`/`job_id` |
| `recognition_complete` | api | roster size, students recognised, frames, detections, rejects by gate (`edge`, `small`, `landmarks`, `brightness`, `blur`), median face size, sample fps, per-stage timings, histogram of reasons |
| `job_failed`, `lease_expired` | api | failed jobs with their code and attempt, and leases that ran out |
| `processing_stalled` | api | a session's jobs have been queued for 90 s or more and no recognition worker has called in. Logged once per session per 5 minutes |
| `database_error`, `unhandled_error` | api | exception type, SQLSTATE or code location. Never the message |
| `job_dispatched`, `claim_paused` | agent | job hand-off to the worker, and why it is not claiming |
| `agent_notice`, `agent_recovered` | agent | recurring problems (API unreachable, credential rejected, broker down), logged once a minute with a repeat count |
| `resources` | agent | CPU %, load, memory available, disk free and used %, queue backlog |
| `job_start`, `download_done`, `inference_done`, `job_done` | worker | each stage with durations |
| `job_failed`, `worker_error`, `lease_lost` | worker | failure code and the **stage** it reached (`input`, `download`, `inference`, `complete`) |
| `client_event` | api | from the apps: `scan_started`, `segment_recorded`, `upload_retry`, `upload_done`, `upload_failed`, `camera_failed`, `camera_interrupted`, `camera_switched`, `api_error`, `app_error`, `scan_stopped` |

**What is never logged:** names, emails, enrolment numbers, tokens, signed URLs, embeddings,
frames, or per-student scores. Logging code drops any field with such a name and any value that
looks like an email, token or URL, and the app diagnostics endpoint only accepts a fixed list of
event names and short numeric or code fields. Do not add free-text fields.

**Reading a failed class:** start with `scripts/logs --vm <session-id>`. A recording that never
processed shows `upload_*` client events and `request` lines for the capture; one that processed
badly shows `recognition_complete` (low `sample_fps`, many `small` or `blur` rejects, a large
`not_seen` count) and the worker's per-stage timings. A teacher reading out the **Reference** line
under an error finds the exact request.

## Capacity and sizing

From 21 November 2026 the VM is `Standard_B4as_v2` (4 vCPU, 16 GB), about 0.098 USD/hour (about 72 USD for a month running 24 hours; retail price, not the Students credit's actual draw).

- **What limits a class.** Face embedding was 85 % of ML time (about 44 ms per face on 2 vCPU). Above `RECOGNITION_EMBED_BUDGET` faces per clip only every k-th frame is embedded, and a job's detection and embedding run on `RECOGNITION_THREADS` threads. Measured on the VM, 20 s clip, about 18 faces per frame, roster 100: 6.1 s per job (11.0 s serial); two at once 13 s each. A job also spends about 9 s in API round trips because the hosted database is in Tokyo, 125 ms away, and every sequential query costs that much.
- **Burst credits.** Baseline is 40 % of the VM (1.6 vCPU). Full use of all four cores draws about 2.4 credits a minute net; the bank caps at 2,304 and refills at 96 an hour. Watch `CPU Credits Remaining` in Azure Metrics if you scan many classes back to back.
- **Region.** The subscription's policy only allows `koreacentral, centralindia, austriaeast, malaysiawest, eastasia`; Japan East is blocked. Korea Central is the realistic region nearer the database, but a new VM changes the hostname (it contains `centralindia`), CORS, the web builds and every installed APK, so do it only between classes, not before a demo. The regional core quota is 6 vCPUs.
- **Not measured:** real 24, 50 or 100-student classes, accuracy under the embed budget on crowded footage, and upload times on a real network.

## Limits to state honestly

- B-series VMs are burstable: long recognition jobs can slow down once CPU credits run out (see Capacity and sizing).
- The InsightFace model permission covers the non-commercial academic demonstration only.
- The phone app still points wherever its APK was built for; a phone build against this server needs `--dart-define-from-file=.local/flutter/production.json`.
