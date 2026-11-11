# ML team quickstart

Start here if you are new to FaceTrack. **Tests use synthetic data** and need no student videos, Supabase account or secret keys. They do not measure face-recognition accuracy.

## 1. Clone and run the safe tests

Install Python **3.11**, [`uv`](https://docs.astral.sh/uv/getting-started/installation/) and FFmpeg/FFprobe. On the existing Mac these are already available. From macOS/Linux:

```sh
git clone https://github.com/rishyym0927/FaceTrack.git
cd FaceTrack
uv sync --locked --python 3.11
.venv/bin/python -m pytest tests -q
cd services/worker
uv sync --locked --python 3.11
.venv/bin/python -m pytest tests -q
```

From Windows PowerShell, use the environment's `Scripts` directory:

```powershell
git clone https://github.com/rishyym0927/FaceTrack.git
cd FaceTrack
uv sync --locked --python 3.11
.venv\Scripts\python -m pytest tests -q
cd services\worker
uv sync --locked --python 3.11
.venv\Scripts\python -m pytest tests -q
```

Expected locally on 27 October: root **42 passing, one expected failure** documenting a frozen alignment limitation; worker **35 passing** (including the Model Test Console). Synthetic DigiFace benchmark results are described in `docs/ML_ACCURACY_AND_ATTENDANCE_PLAN.md` sections 9 and 10; real-volunteer testing uses `docs/MODEL_TEST_CONSOLE.md`. A fresh clone may report a different count after new tests land. If a command fails, copy the **error code and command**, not private `.env` contents, into your team issue. `uv sync` installs into each directory's own `.venv`; do not use the system Python or change the root `uv.lock` for worker dependencies.

## 2. Understand the ML flow

`video → sample frames → detect faces → reject poor crops → align → 512D embeddings → compare only with the session roster → require separated matching frames → faculty reviews suggestion`.

The code is in `services/worker/src/facetrack_ml`. The worker bridge is in `services/worker/src/facetrack_worker`. Unit tests are in `tests` and `services/worker/tests`. Read `MASTER_DESIGN.md` for requirements, `PROGRESS.md` for the actual checkpoint and `docs/ML_SPIKE.md` for the detailed experiment guide.

No training is necessary for this demo: enrolment stores encrypted templates from a pretrained model. A matching result is **not** proof of identity, liveness or attendance. See the [product attendance rules](../MASTER_DESIGN.md#attendance) for draft marks and faculty publication.

## 3. Authorized demo operator only

Real recognition needs separately provisioned, permission-reviewed model weights, an ignored manifest/profile and private service configuration. A clone intentionally lacks them. Never copy weights, recordings, templates, credentials or test results into Git or chat. The current weights are approved only for the strictly non-commercial academic experiment; institute deployment needs its own rights review.

From the existing provisioned Mac, first run:

```sh
python3 scripts/check_ml_freeze.py
```

It should say **16/16 verified**. If not, stop real held-out testing; do not regenerate the receipt or overwrite frozen files. Start the product with `docs/INSTALLATION.md`; Windows-specific checks are in `docs/WINDOWS_SETUP.md`. Then open `http://127.0.0.1:8000/health/ready`. Restore the platform's USB forwarding after a reconnect. Follow `docs/ML_SPIKE.md` for consented capture, 24-hour raw-media cleanup and held-out evaluation.

After a private held-out evaluation, this prints **aggregate counts only**; it treats repeated runs of one clip as a stability check, not extra accuracy samples:

```sh
.venv/bin/python scripts/summarize_ml_evaluation.py .local/spike/results/YOUR-PRIVATE-REPORT.json
```

To check whether exact NumPy matching is a bottleneck **without personal data**, run `.venv/bin/python scripts/benchmark_match.py`. It times matching only; it does not measure detection, network, queue delay or 20 concurrent classrooms.

The five missing scenarios are one enrolled person absent, unknown alone, known plus unknown, changed position/pose, and no face. Use **new Test clips**, never reference or calibration footage. Preserve failed runs. Do not tune the frozen profile using these clips.

## 4. Small contribution tasks

| Task | First action | Finished when |
|---|---|---|
| Evaluation | Check the freeze receipt and prepare pseudonymous case labels | Every available held-out clip has independent ground truth and a saved private result. |
| Capture quality | Review aggregate rejects, room light and face size | Suggestions are compared against the unchanged baseline on calibration clips. |
| Worker reliability | Run synthetic media, retry and restart tests | A failure leaves attendance unassessed and no job commits twice. |
| Demo operation | Practice starting the six processes and recovery | Another authorized member can follow this guide without sharing secrets. |

Before opening a PR, run the relevant tests and `ruff check` in the edited Python environment. Explain what was **implemented** versus **verified with real video**. Preserve the 16 frozen files and keep new model experiments in separate versioned profiles/data roots.

## 5. Research after the demo

Use the [WIDER FACE validation set](https://shuoyang1213.me/WIDERFACE/index.html) only under its non-commercial licence to study small-face detection; do not upload its images to Supabase or commit them. Face-verification datasets can test embedding behavior only after their own rights and protocol are checked. They do not measure attendance accuracy in this institute. Compare one proposed change at a time—lighting correction, tiled detection, pose filtering or a licensed larger model—against the frozen baseline on **calibration** data. Track false proposals, misses, rejected faces and total time. Model fine-tuning is a later task requiring appropriate data rights, an independently versioned model and fresh held-out evaluation; it is not needed to run the demo.
