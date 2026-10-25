# FaceTrack local processing worker

The verified demo uses one CPU slot on the Mac for enrolment, classroom recognition, timetable parsing and CSV/PDF report rendering; Windows runs the same worker inside the provided Linux container. PostgreSQL owns job state; private local Redis carries only job/lease identifiers. The outbound agent claims scoped work and performs periodic reconciliation. Real classroom processing remains an acceptance gate: do not infer it from synthetic tests or worker startup.

## Environment and startup

Windows users should use [the root Windows guide](../../docs/WINDOWS_SETUP.md). Celery is not supported as a dependable native Windows worker, so `compose.windows.yaml` runs Celery and Redis on Linux while Flutter remains native.

For the verified macOS path, use this service's Python 3.11 `.venv` and `uv.lock`, leaving the root ML environment/lock untouched. Provisioning is described in `../api/README.md`; existing private `.env` and root `.local/enrollment/redis.conf` are already configured. Never print either file. The worker receives a scoped token, local broker URL and verified model/profile paths, never database credentials or the Storage secret. Its token expires 30 days after provisioning; revocation/reprovisioning is an operator action.

From the repository root, start Redis in a dedicated terminal:

```sh
redis-server .local/enrollment/redis.conf
```

Start the API using its README. From `services/worker`, use two terminals:

```sh
.venv/bin/python -m celery -A facetrack_worker.executor:app worker --pool=solo --concurrency=1 --loglevel=WARNING --without-gossip --without-mingle
```

```sh
.venv/bin/python -m facetrack_worker.agent
```

For a clean environment, use the installed `uv` executable: `uv sync --locked` from this service only. It resolves the root ML library as an editable dependency but does not install or alter the root environment. FFmpeg/FFprobe must be available on PATH. A single spawned process bounds inference; a separate heartbeat thread renews the 120-second lease every 15 seconds. Three total transient attempts are permitted. Expired lease holders cannot commit. Redis may be restarted without treating its queue as the source of truth.

## Processing and privacy

The API authorizes a short-lived input download. The worker checks origin, size and SHA-256; media jobs also check container, duration, decoded content and absence of audio. Rotated phone video is normalized through a bounded FFmpeg adapter before the frozen reader; source and normalized hashes are retained separately. It does not enhance faces, strip disallowed audio, prove liveness or label individual template poses. Enrolment collects 3–5 normalized 512D vectors in memory; the API encrypts them before teacher review. Recognition loads only the eligible, pinned session roster in memory and returns suggestions; it never publishes attendance. Never reuse prototype participant templates.

Timetable jobs parse the exact bounded UTF-8 CSV and the API validates academic references/overlaps. Report jobs receive an immutable publication snapshot, render bounded CSV/PDF with pandas/ReportLab, and return bytes to the API; only the API writes private Storage artifacts. Optional Resend delivery uses the API's secret and a verified faculty recipient; no email provider is configured now. Keep a single worker slot for the USB demo and measure actual throughput before claiming institute capacity.

Temporary files use private managed directories and are removed on completion/failure. Abandoned owned directories are reconciled at startup/periodically. Storage cleanup runs on agent startup and every minute while awake, removing decided/expired recordings and reconciling late uploads through signed-grant expiry. A sleeping/offline development computer delays cleanup. The agent emits a sanitized backlog warning; investigate rather than claim a continuous retention guarantee.

## Verification

```sh
.venv/bin/python -m pytest tests -q
```

Seven worker tests exercise real FFmpeg on synthetic rotated/audio/corrupt inputs, deterministic timetable/report output and the restricted container-network configuration. They do not validate participant recognition. Backend lifecycle tests separately cover leases, duplicate effects, consent/replacement/revocation, ownership, timetable conflicts and reports. Record actual fresh-device processing and human teacher decisions before completing any attendance milestone. Model permissions remain limited to the approved non-commercial academic experiment.
