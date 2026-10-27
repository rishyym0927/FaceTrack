# ML model, provenance and held-out evaluation

Run shell commands below from the repository root unless a section says otherwise. This guide covers the frozen model's provenance and permission gate, the research CLI (`scripts/spike`) and the held-out evaluation protocol, as run on the verified Mac; Windows users should use `docs/WINDOWS_SETUP.md` to run the product and translate `.venv/bin/python` to `.venv\Scripts\python` only for authorized local ML experiments. The active product architecture is in ../MASTER_DESIGN.md.

## Installed environment

The project-local Flutter SDK is `.tools/flutter` (stable 3.47.7 / Dart 3.13.5). Python 3.11.15 is isolated in `.tools/python` and `.venv`; system Python is unchanged. Python dependencies are locked in `uv.lock`, Flutter dependencies in each app’s `pubspec.lock`. FFmpeg/FFprobe are installed through Homebrew. SDKs and all local biometric data are ignored by Git.

From the project root:

```sh
export UV_CACHE_DIR="$PWD/.cache/uv"
export UV_PYTHON_INSTALL_DIR="$PWD/.tools/python"
uv sync --locked
scripts/spike doctor
```

To reproduce Flutter, use the recorded stable version, not an unpinned upgrade. `.tools/flutter/bin/flutter --version` reports the exact framework/engine revisions.

## Capture a clip

```sh
cd apps/teacher
../../scripts/flutter run -d chrome -t lib/main_spike.dart --web-hostname localhost --web-port 5302
```

Click **Enable camera**, confirm participants' explicit consent, then record. Enrolment auto-stops after 15s and prompts front plus four shuffled poses. Classroom capture auto-stops after 10s. Audio is disabled. Review playback; save video and metadata using separate buttons so browsers do not block a second automatic download.

Use IDs such as `p01` and `p02`, not real names. Save into `.local/spike/media` under the project root. If Chrome saves to Downloads, move the files and delete leftover copies. Cleanup only manages the project media directory; it cannot clean arbitrary Downloads copies or a browser tab left open. Close/discard the tab after use. Record enrolment references separately from calibration and held-out test videos.

```sh
scripts/spike probe .local/spike/media/your-clip.webm
scripts/spike probe .local/spike/media/your-clip.webm --metadata .local/spike/media/your-clip.json
scripts/spike cleanup
```

`cleanup` removes regular managed raw media/sidecars older than 24h, never keys/templates or symlink targets. Run it before and after a recording session and at least daily while footage exists. It is not an installed automatic background service; retention while the Mac is asleep remains an operator responsibility in this local spike.

Paired validation checks consent/audio declarations, mode/dataset, pseudonymous identity, prompt coverage and duration against the actual container (1.5s tolerance for browser stop timing). Actual audio streams are rejected. The existing JSON exports contain no video hash: pairing is supplied by the operator, and passing these checks cannot prove identity, consent or performed poses. Enrolment also accepts optional `--metadata FILE` to check reference identity before loading models; the explicit consent and supervised-review flags remain mandatory.

Chrome WebM sometimes omits its average frame rate. The validator then inspects bounded video-packet timestamps rather than rejecting the recording or trusting the nominal 1000fps time base. The existing duration, size, resolution, rate and packet-count limits still apply; no re-encoding is required for that metadata issue.

## Model permission and manifest gate

`models/manifest.example.json` documents the adapter contract, **not verified real artifacts**. Running it returns `MODEL_PERMISSION_REQUIRED` before constructing an ONNX session.

Initial target: SCRFD with 3 strides (8/16/32), two anchors/location and nine heads (scores, boxes, landmarks), plus a 512D ArcFace-trained MobileFaceNet recognizer with 112px input. The implementation uses top-left letterbox padding, RGB NCHW inputs and explicit manifest normalization. Models with different contracts must not be relabelled to fit.

Before real inference:

1. Obtain artifacts whose terms permit this exact local project use. Public InsightFace weights are research-restricted; a paid final-year implementation is not automatically permitted. Institute deployment requires separate rights. See [upstream terms](https://github.com/deepinsight/insightface/blob/master/python-package/README.md).
2. Copy the example to `.local/spike/models/manifest.json`. Place the actual binaries and written licence/permission evidence alongside it. Never commit these files.
3. Record original source URLs, actual input/output tensor names, artifact SHA256s and verified preprocessing. Use `shasum -a 256 FILE` to calculate hashes.
4. Have the responsible reviewer document allowed `local_poc` use, reviewer/date and evidence hash, then set status to `approved`. The code checks recorded evidence/integrity; it cannot itself establish legal permission.
5. Verify actual CPU execution:

```sh
scripts/spike models --manifest .local/spike/models/manifest.json
```

The official v0.7 `buffalo_sc` package is now provisioned locally at `.local/spike/models/buffalo_sc/`, after the user confirmed a strictly non-commercial academic experiment. Its `det_500m.onnx` and `w600k_mbf.onnx` artifacts pass CPU contract execution; real reference detection/embedding has also run. The local manifest records actual tensor names, SHA-256s and scoped licence evidence. It does not permit paid delivery or institute use. Sources: [official model catalogue](https://github.com/deepinsight/insightface/blob/master/python-package/docs/model_zoo.md), [official release](https://github.com/deepinsight/insightface/releases/tag/v0.7). Reproducing this setup requires a fresh intended-use review; do not copy an approval into another use case.

`scripts/fetch-model.sh` (macOS/Linux) and `scripts/fetch-model.ps1` (Windows) download that same official `buffalo_sc.zip`, verify its SHA-256 (`57d31b56…de47c72`) and extract the two ONNX files into `.local/spike/models/buffalo_sc/`. They do **not** create `manifest.json`, `license-evidence.json` or the frozen profile; those stay private and come from the project owner, because they record the reviewed permission. Synthetic ONNX test graphs remain contract tests only.

## Freeze an experimental profile

Thresholds are explicit; there is no hidden production default. Run `scripts/spike profile --help` to supply the manifest, calibration identifier, identity threshold, distinct-identity margin and enrolment consistency threshold. Keep profiles under `.local/spike/profiles/`.

```text
scripts/spike profile --manifest MANIFEST --out NEW_PROFILE \
  --calibration-id CALIBRATION_RUN \
  --identity-threshold MEASURED_VALUE \
  --minimum-margin MEASURED_VALUE \
  --enrollment-consistency MEASURED_VALUE
```

The placeholders must be replaced with values from the model's documented baseline and your separate calibration experiment; they are not executable example numbers. Profiles cannot overwrite an existing file. The full profile hash binds local templates: if changing a profile during calibration, use a separate local data root and regenerate templates from the enrolment reference clips. Freeze the final profile **before** running held-out tests; report all misses and false matches. This tiny sample does not establish a >95% accuracy claim.

`profile` also accepts `--blur-variance MEASURED_FLOOR` (default 40, unchanged). The first both-known calibration clip demonstrated excessive rejection at the initial floor; inspecting rejected crops is diagnostic only. Calibrate quality settings alongside matching using known and unknown recordings before freezing. Changing this floor changes the profile hash and requires new template sets. Disabling the filter to inspect scores does not pass acceptance.

### Selected baseline and independent testing

All six calibration scenarios now match expected identity sets on three fresh-process runs each. Sampled mixed-face assignments also match user-confirmed positions. Earlier one-absent and variation misses remain preserved. Unknown identity remains unenrolled. Calibration success does not establish held-out accuracy or production readiness.

The selected profile is `.local/spike/profiles/frozen-phase1b-v1.json`, a byte-identical copy of candidate v3. Use existing encrypted templates at `.local/spike/experiments/calibration-v3` and the same model manifest. The active receipt is `.local/spike/held-out-freeze-v2.json`; it supersedes the preliminary receipt before any independent testing, solely for evaluator support of retained exclusion hashes. Inference, profile and templates stayed unchanged. Before each held-out processing session:

```sh
.venv/bin/python - <<'PYVERIFY'
import json
from pathlib import Path
from facetrack_ml.config import digest
receipt = json.loads(Path('.local/spike/held-out-freeze-v2.json').read_text())
assert all(digest(Path(path)) == expected
           for path, expected in receipt['frozen_files_sha256'].items()), 'Frozen input changed'
print('Frozen inputs verified')
PYVERIFY
```

Capture six **new** 10-second videos in **Classroom / Test**, with consent. Participant ID only labels the classroom clip:

| Scenario | People visible | Clip ID label |
|---|---|---|
| Both known | p01 + p02 | p01 |
| One absent | p02 alone | p02 |
| Unknown only | Same unenrolled person alone | p03 |
| Mixed unknown | p01 + unknown; keep p01 on right in playback and confirm | p01 |
| Variation | p01 + p02, gentle turns and changed positions/distance | p01 |
| No face | Empty scene | p01 |

The first independent both-known Test clip now passes three fresh-process identity-set checks with no configuration changes (1/6 scenarios). Evidence is in `.local/spike/results/held-out-both-known-v1-evaluation.json`; accumulated case/provenance information is in `.local/spike/held-out-progress-v1.json`. A previously re-exported calibration clip was excluded; test exclusions now include its digest too.

Save video and metadata for each, with Test selected. Do not reuse any reference/calibration recording or tune settings using these clips. Replace query placeholders in `.local/spike/test-suite.example.json` and save a new private suite. Its exclusion digests cover two references and all six calibration clips; retain those digests after deleting expired raw footage. For individual processing, after receipt/exclusion checks:

```text
scripts/spike --data-root .local/spike/experiments/calibration-v3 recognize TEST_VIDEO \
  --roster p01 p02 --manifest .local/spike/models/buffalo_sc/manifest.json \
  --profile .local/spike/profiles/frozen-phase1b-v1.json --out NEW_PRIVATE_RESULT
```

Preserve failures and leave identities unassessed. A needed configuration change begins a new version and a fresh held-out recording set. Do not overwrite prior evidence. Full calibration suite/report: `.local/spike/calibration-suite-v5.json` / `.local/spike/results/calibration-v6-evaluation.json`. Earlier misses: `calibration-v3-evaluation.json` and `variation-calibration-v2-evaluation.json` under results. The old candidate-v1 benchmark is historical; do not relabel it as a selected-profile measurement.

## Enrol, recognize, benchmark and revoke

The commands below are a fresh-experiment example, not instructions to overwrite or revoke the active frozen evaluation set. Use a separate private `--data-root` and an explicitly created compatible profile for new experiments; use the selected-baseline section for the current held-out run.

Enrolment requires an explicit consent confirmation and a supervisor's review of actual identity and all five requested poses. The sidecar records prompts; it is not proof that the person performed them. Automatic head-pose/liveness verification is not implemented.

```sh
scripts/spike enrol .local/spike/media/p01-reference.webm \
  --participant p01 --consent --supervised-pose-review \
  --manifest .local/spike/models/buffalo_sc/manifest.json \
  --profile .local/spike/profiles/frozen.json

# Repeat enrolment for p02 using their own reference clip.
scripts/spike recognize .local/spike/media/classroom-test.webm \
  --roster p01 p02 --manifest .local/spike/models/buffalo_sc/manifest.json \
  --profile .local/spike/profiles/frozen.json --out .local/spike/results/test.json

scripts/spike benchmark .local/spike/media/classroom-test.webm \
  --roster p01 p02 --runs 3 --manifest .local/spike/models/buffalo_sc/manifest.json \
  --profile .local/spike/profiles/frozen.json --out .local/spike/results/benchmark.json

scripts/spike revoke --participant p01
```

Only supplied roster identities are matched. At least two identities are required because the profile uses a best-versus-second-distinct-person margin. Unknowns remain unassigned; missing proposals are `unassessed`, not absent. Corroboration requires separated timestamps; duplicate pixels and conflicting simultaneous matches do not create extra evidence. No tracking/duration-of-attendance or authoritative attendance is claimed.

Templates are AES-256-GCM encrypted with a private random local key; keep key and ciphertext out of Git. Revocation deletes the local ciphertext, immediately removing that identity from subsequent runs. No raw face crops are saved. Results contain pseudonyms, hashes and summarized scores/timings, never embedding arrays.

Timings include model initialization/warmup, decoding, detection, embedding, matching and processing total. Processing total excludes initialization, so full run cost includes `cold_start_ms` separately. The current adapter runs batch-one inference for compatibility; multi-image batching and CoreML optimization are not yet validated.

## Checks

### Calibration and held-out evaluation

Use two reference identities (`p01`, `p02`) and keep `p03` unenrolled. Collect independent **calibration** and **test** classroom exports for both known people, one absent person, unknown alone, known plus unknown, varied positions/poses, and no faces. Record expected visible identities manually. For no-face footage, keep everyone out of view; blurred footage with a person is a separate negative-quality test, not a no-face label.

Private suite examples are prepared under `.local/spike/calibration-suite.example.json` and `.local/spike/test-suite.example.json`; update their placeholder export paths and save your working copies there. Each suite has `schema_version: 1`, `dataset`, `roster` and `cases`; exclusions use `excluded_videos` and/or `excluded_media_sha256` (at least two distinct fingerprints overall). Paths in it are relative to the suite file. Each case supplies `case_id`, `scenario`, `video`, `metadata`, and `expected_present` (enrolled identities only). `scenario` is one of `both_known`, `one_absent`, `unknown_only`, `mixed_unknown`, `variation`, `no_face`.

List **all reference videos** in `excluded_videos`; for a test suite include **all calibration videos** too. Alternatively supply their SHA-256s in `excluded_media_sha256`, taken from the freeze receipt; this keeps the exclusion check working after raw-media cleanup. The evaluator checks hashes against this list and rejects duplicated cases and incorrectly labelled datasets. It cannot discover omitted recordings or verify operator ground truth.

For each candidate configuration, use the existing `profile` command and a fresh `--data-root`, re-enrol both references, then evaluate only calibration clips. Choose settings that reject unknowns and do not create false presence proposals while retaining corroborated known matches. If none passes, investigate capture/model behavior; do not relax the held-out checks. Freeze the selected profile before test execution. Preserve failed experiments, and use newly collected held-out clips if subsequent changes are informed by a test failure.

```sh
.venv/bin/python scripts/evaluate_spike.py \
  --suite .local/spike/test-suite.json \
  --manifest .local/spike/models/buffalo_sc/manifest.json \
  --profile .local/spike/profiles/frozen-phase1b-v1.json \
  --data-root .local/spike/experiments/calibration-v3 \
  --out .local/spike/results/held-out-01.json --repeats 3
```

The runner records an immutable input receipt before inference and refuses output reuse. It launches a fresh Python process for each repetition and records process wall time plus model initialization/warmup, decoding, detection, embedding, matching and total processing timings. Errors remain failed runs, never empty successful results. All six scenarios must be present for automated set checks to pass. Exit 1 means incomplete/failed checks; exit 2 means invalid inputs. Exit 0 still requires human review, especially unknown-face attribution in mixed clips: correct proposed identity sets do not prove which face produced a match. Repeated clips measure stability/speed, not additional independent accuracy samples. No aggregate production accuracy percentage is calculated.

### Automated checks

```sh
.venv/bin/ruff check services/worker tests scripts/evaluate_spike.py
.venv/bin/pytest tests -q
cd apps/teacher
../../scripts/flutter analyze
../../scripts/flutter test
../../scripts/flutter build web -t lib/main_spike.dart --output build/spike
```

Run shared product tests separately from `packages/app_core` with `../../scripts/flutter test`; backend tests use the isolated service environment and commands in `services/api/README.md`. Current verified counts are maintained in `PROGRESS.md`; do not infer recognition accuracy from any automated-test count.

Python tests use mathematical vectors, synthetic ONNX graphs and generated non-biometric MP4/WebM videos. Capture tests use a fake camera; shared product tests use explicitly synthetic Auth/API fixtures. These verify implementation behavior, not recognition quality or real camera permission/recording.

For real acceptance, recruit at least three consenting adults: two enrolled and one unknown. Record independent query clips with both enrolled people, an absent enrolled person, the unknown, varied pose/glasses/positions, and poor/no-face footage. Keep a manual ground-truth record outside Git, compare every proposal, and preserve failures. Run on the actual camera/browser; synthetic tests cannot complete this gate. The [Model Test Console](MODEL_TEST_CONSOLE.md) packages exactly this protocol (enrolment, six scenarios, three repeats, readable report) for a nontechnical tester.

Read `MASTER_DESIGN.md` for architecture, `ROADMAP.md` for milestones and `PROGRESS.md` for current verification and remaining blockers.
