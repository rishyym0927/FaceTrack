# FaceTrack local processing worker

The worker processes enrolment, classroom recognition, timetable parsing and CSV/PDF rendering.
The macOS demo runs one CPU slot. Docker Compose runs the worker and agent in Linux containers,
including the Azure deployment and the Windows setup. PostgreSQL owns durable job state, private
Redis carries job IDs and lease epochs, and the agent claims work and reconciles stale jobs.

## Environment and startup

Use the canonical [installation guide](../../docs/INSTALLATION.md). Windows users should also read [the Windows checklist](../../docs/WINDOWS_SETUP.md). Celery is not a supported native Windows runtime here, so the canonical Compose stack runs Celery and Redis in Linux containers while Flutter remains native.

For the verified macOS path, use this service's Python 3.11 `.venv` and `uv.lock`, leaving the root ML environment/lock untouched. Use the [API guide](../api/README.md#provisioning) to provision the private worker `.env` and repository-root `.local/enrollment/redis.conf` before native startup. The worker receives a scoped token, local broker URL and verified model/profile paths, never database credentials or the Storage secret. Its token expires 30 days after provisioning; revocation/reprovisioning is an operator action.

From the repository root, start Redis in a dedicated terminal:

```sh
redis-server .local/enrollment/redis.conf
```

Start the API using its [native startup instructions](../api/README.md#native-development). From `services/worker`, use two terminals:

```sh
.venv/bin/python -m celery -A facetrack_worker.executor:app worker --pool=solo --concurrency=1 --loglevel=WARNING --without-gossip --without-mingle
```

```sh
.venv/bin/python -m facetrack_worker.agent
```

For a clean native environment, run `uv sync --locked --python 3.11` from this service only. It resolves the root ML library as an editable dependency but does not install or alter the root environment. FFmpeg/FFprobe must be available on PATH; the worker Docker image already installs FFmpeg. A spawned process bounds inference, and a separate heartbeat thread renews the 120-second lease every 15 seconds. Transient failures allow up to three attempts. PostgreSQL reconciliation recovers lost Redis dispatches and rejects commits from expired leases.

### Runtime settings

Use the provisioned `.env` and the field names in [`.env.example`](.env.example).

| Setting | Purpose |
| --- | --- |
| `API_BASE_URL`, `WORKER_TOKEN` | Worker API origin and scoped credential |
| `REDIS_URL` | Private loopback Redis broker for native startup |
| `MANIFEST_PATH`, `PROFILE_PATH` | Approved model manifest and frozen matching profile |
| `MEDIA_ORIGIN` | Exact Storage origin used to validate download grants |
| `TEMP_ROOT` | Private scratch directory for job inputs and results |

Compose sets `FACETRACK_CONTAINER_NETWORK=1` and supplies private `api` and `redis` hostnames
and container paths. Use the token and Storage origin provisioned for that backend.

## Processing and privacy

The API authorizes a short-lived input download. The worker checks origin, size and SHA-256; media jobs also check container, duration, decoded content and absence of audio. Rotated phone video is normalized through a bounded FFmpeg adapter before the frozen reader; source and normalized hashes are retained separately. It does not enhance faces, strip disallowed audio, prove liveness or label individual template poses. Enrolment collects 3–5 normalized 512D vectors in memory; the API encrypts them before teacher review. Recognition loads eligible templates for the pinned session roster in memory and returns suggestions. Publication requires a teacher decision in the API. Never reuse prototype participant templates.

Timetable jobs parse the exact bounded UTF-8 CSV and the API validates academic references/overlaps. Report jobs receive an immutable publication snapshot, render bounded CSV/PDF with pandas/ReportLab, and return bytes to the API; only the API writes private Storage artifacts. Optional Resend delivery uses the API's secret and a verified faculty recipient. The demo uses private report downloads. Keep a single worker slot for the USB demo and measure actual throughput before claiming institute capacity.

Temporary files use private managed directories and are removed on completion/failure. Abandoned owned directories are reconciled at startup/periodically. Storage cleanup runs on agent startup and every minute while awake, removing decided/expired recordings and reconciling late uploads through signed-grant expiry. A sleeping/offline development computer delays cleanup. The agent emits a sanitized backlog warning; investigate rather than claim a continuous retention guarantee.

## Verification

From `services/worker`:

```sh
.venv/bin/python -m pytest tests -q
```

Tests cover FFmpeg handling of synthetic rotated, audio and corrupt inputs, deterministic timetable
and report output, worker job behavior and the restricted container network. See the
[checkpoint](../../PROGRESS.md) for current suite results and physical-device acceptance.

The optional [Model Test Console](../../docs/MODEL_TEST_CONSOLE.md) lives in
`facetrack_worker.console`. Its Compose profile binds to host loopback and runs separately from
attendance processing. See the console guide for approved client deployments and data handling.
Model permissions remain limited to the approved non-commercial academic experiment.
