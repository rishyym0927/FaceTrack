# ML accuracy experiments

This package is research-only and is never imported by the product API or worker. It keeps the
receipt-pinned baseline unchanged while testing detector preprocessing, quality gates and detector
alternatives on immutable inputs.

All dataset files belong outside Git and Supabase. Start from `candidates.json`; write manifests and
aggregate CSV/JSON results to an ignored `.local/experiments/` directory. Cells that have not been run must stay
`Not measured yet`. A candidate may enter the product only as a new model release and recognition
profile after the documented accuracy, repeatability and latency gates pass.

The five-landmark value in `FivePointYawResearch` is an uncalibrated asymmetry score. Do not call it
degrees or enable it as a gate until it has been validated against BIWI ground-truth rotations.

To freeze the DigiFace selection after the licensed dataset is stored locally, create a JSON index
mapping synthetic identity IDs to relative image paths, then run:

```bash
.venv/bin/python -m experiments.ml_accuracy.build_manifest INDEX.json \
  .local/experiments/digiface/manifest.json --dataset-root /absolute/path/to/DigiFace
```

The command selects 80 calibration and 120 held-out identities, uses three disjoint enrolment images
and two query images per identity, and specifies ten deterministic scenes for each of the six required
attendance scenarios. Freeze the printed manifest hash before generating or evaluating videos.
The saved manifest uses opaque identity and asset IDs plus source hashes; it does not copy dataset
paths or images. `write_aggregate_results` writes only overall and per-scenario CSV/JSON metrics, never
participant-level rows, identity labels or embeddings.

## Synthetic benchmark

`run_synthetic.py` composites DigiFace faces into 60 scenes of 12 frames with easy/medium/hard degradations, then runs the frozen baseline or a candidate variant (`baseline`, `clahe_detector_only`, `contrast_filter`, `two_scale`):

```bash
.venv/bin/python -m experiments.ml_accuracy.run_synthetic prepare --zip DIGIFACE.zip --out .local/experiments/digiface/results
.venv/bin/python -m experiments.ml_accuracy.run_synthetic run --zip DIGIFACE.zip --manifest .local/experiments/digiface/results/manifest.json --variant baseline --run 1 --out .local/experiments/digiface/results
```

Results are written to the ignored `.local/experiments/digiface/results/`. They are a SYNTHETIC BENCHMARK, not classroom accuracy; see `docs/ML_ACCURACY_AND_ATTENDANCE_PLAN.md` section 9.
