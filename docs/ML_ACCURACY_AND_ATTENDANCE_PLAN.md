# FaceTrack ML Accuracy and Attendance Plan

**Status:** Implementation foundation complete; the DigiFace synthetic benchmark has been run (section 9); WIDER, BIWI and alternate-detector results remain **Not measured yet**.  
**Scope:** Strictly non-commercial academic research. Production ML baseline remains frozen.

## 1. Decisions

FaceTrack keeps SCRFD-500M plus the ArcFace-trained MobileFaceNet recognizer as the presentation baseline. Exact NumPy cosine matching remains appropriate because every recognition job searches only its frozen class roster and current timings show matching is negligible compared with detection and embedding. FAISS will be reconsidered only if a measured roster-search bottleneck appears.

Accuracy changes run only in `experiments/ml_accuracy`. They use separate manifests, profiles, data roots and result folders and are never imported by the API or product worker. A candidate becomes eligible for product adoption only as a new model release and recognition profile.

Attendance uses a teacher-confirmed automatic draft:

- A corroborated identity becomes `proposed_present`.
- An eligible student without a corroborated match after a sufficiently usable, successful capture becomes `proposed_absent`, displayed as **Not recognized**.
- Template-ineligible students, limited captures and processing failures remain `unassessed`.
- Teachers must convert every proposal to an explicit final status before publication.
- A similarity score is evidence of resemblance, not a probability of attendance or absence.

Students may query their own latest published Absent result. The assigned teacher accepts or rejects the query with a reason. Acceptance records Present and creates a new immutable publication and corrected report. V1 has in-app status only; push, email, evidence uploads and geolocation are deferred.

## 2. Current methodology status

| Technique | Current product status | Experiment |
|---|---|---|
| CLAHE | Not implemented | LAB luminance correction on detector pixels only; recognition uses original pixels |
| Multi-scale SCRFD | Internal stride 8/16/32 heads and NMS, but one 640 input | Two full inputs at 640 and 960, original-coordinate mapping and global NMS |
| Blur and contrast | Minimum face size, mean exposure and Laplacian blur are implemented | Add optional grayscale standard-deviation contrast rejection |
| Yaw | No server yaw filter; Student live pose guidance is advisory | Validate a five-landmark asymmetry proxy against BIWI before interpreting it as degrees |
| Temporal fusion | Implemented | Preserve two unique timestamps spanning at least 500 ms |
| Detector alternatives | SCRFD-500M baseline only | RetinaFace-R50 after artifact verification; SCRFD-2.5G-KPS as practical alternative |

Ordinary video is not liveness protection. Current capture guidance and temporal corroboration improve quality and reduce single-frame errors, but they do not prove that a live person is present.

## 3. Experimental package

The research package provides:

- Composable detector-frame preprocessing that preserves original recognition pixels.
- True two-scale SCRFD decoding with input-derived grids and one global NMS.
- Independent exposure, blur, contrast, landmark and research-pose gates.
- Per-crop alignment failure handling with `alignment_rejects`.
- A deterministic, pseudonymous DigiFace manifest builder with source hashes and a 60-scene specification.
- Aggregate-only CSV/JSON metrics that keep false presence, unknown false identification, misses, coverage and unassessed rate separate without emitting identity-level rows.
- An eight-candidate matrix in `experiments/ml_accuracy/candidates.json`, with synthetic DigiFace results recorded for the four measured variants and every other cell still **Not measured yet**.

RetinaFace-R50 and SCRFD-2.5G-KPS adapters remain blocked until each artifact’s official source, tensor contract, hash and research permission are recorded. No compatible file is silently substituted.

## 4. Dataset protocol

### WIDER FACE detection

Use the complete validation split and official annotations outside Git and Supabase. Report Easy, Medium and Hard AP; recall at IoU 0.5; recall by blur, illumination, occlusion and pose; small-face recall; false detections per image; median/p95 CPU inference time; and peak memory.

### DigiFace attendance simulation

1. Index identities with at least five images.
2. Freeze a deterministic selection of 200 identities.
3. Use 80 identities only for calibration and 120 only for held-out testing.
4. Use three images per identity for enrolment and two disjoint images for queries.
5. Generate ten 1280×720 videos for each scenario: both known, one absent, unknown only, known plus unknown, position/scale variation and no face.
6. Apply deterministic illumination, glare, blur, compression and partial occlusion parameters.
7. Freeze the manifest and SHA-256 before evaluating any candidate.
8. Execute every candidate three times in fresh processes.

Dataset images, vectors and identity-level results remain private and outside version control. Aggregate CSV/JSON outputs contain no images, embeddings, names or secrets.

## 5. Metrics and gates

Report proposed-present precision/recall, unknown-person false identification, absent-student false presence, missed-present count, coverage, unassessed rate, stability, cold start, decode, detection, embedding, matching and total wall time. Confidence intervals must be clustered by video and identity.

A candidate may be adopted only when:

- False-presence performance does not worsen.
- Held-out recall or coverage improves.
- Three fresh-process runs are stable.
- A 10-second clip remains within 2 seconds local p95 worker processing time.
- Artifact rights and model contracts are verified.
- The simplest Pareto-optimal candidate is selected.

These results must be labelled **synthetic benchmark performance**. They do not establish >95% classroom accuracy, two-second end-to-end response, liveness, 20 simultaneous classes or deployment rights.

## 6. Reliability and security tests

Required automated checks cover degenerate landmarks, coordinate mapping, cross-scale NMS, CLAHE determinism, original recognition pixels, quality-reason counters, no/multiple faces, corrupt/audio/rotated media, duplicate frames, unknown identities, absent members, stale template epochs, worker timeout/restart/stale lease/duplicate completion, proposed absence only after usable successful processing, manual locks, immutable publication, dispute authorization, cross-tenant denial and idempotent resolution.

## 7. Delivery order

1. Preserve and verify the 16-file production freeze.
2. Keep the locally and hosted-verified migration 0007 evidence/query contract covered by regression tests.
3. Run the Model Test Console with real volunteers (client and developer rehearsal) and record the result in `PROGRESS.md`.
4. Complete and safely accept the Student and Teacher attendance-query interfaces on authenticated web/Android clients.
5. Freeze dataset indexes and hashes after the licensed datasets are obtained.
6. Run the baseline first and publish aggregate machine-readable results.
7. Run one change at a time, then accepted combinations.
8. Rehearse the existing stable demo without replacing its detector.
9. After the presentation, complete real classroom validation, model-rights review and measured 20-class capacity testing.

## 8. Current blockers

- WIDER FACE and BIWI are not stored locally; licences and downloads must be handled outside Git. A DigiFace archive is stored locally (ignored) and used for the synthetic benchmark.
- RetinaFace-R50 and SCRFD-2.5G-KPS artifacts are not provisioned or contract-verified.
- Five independent real participant scenarios remain unavailable.
- Windows and cloud inference remain implementation paths without physical acceptance.
- Current public InsightFace pretrained weights are approved only for the confirmed non-commercial academic experiment.

## 9. Synthetic benchmark results (26 October)

**Synthetic benchmark (26 October):** 60 DigiFace scenes (6 scenarios × 10, 12 frames each, 30-student roster; 60 present students in total) run through the unchanged frozen baseline, 3 fresh-process runs per variant, identical decision digests. Baseline: **0 wrong-present marks** (also 0 false presences in unknown-only scenes), 22 of 60 present students suggested (easy 20/24, medium 2/18, hard 0/18), median ≈0.1 s and p95 ≈0.18 s per 12-frame scene. Most misses come from the quality gate: faces found easy 342/384, medium 196/288, hard 76/288, but usable (passed the gate) only 218, 35 and 0. Two-scale SCRFD suggested 24/60 (+2) with 0 false presence at median ≈0.42 s/p95 ≈0.56 s; detector-only CLAHE changed nothing (22/60); the contrast filter was worse (18/60). Two-scale meets the numeric synthetic gates but is **not adopted**: the gain is two students on synthetic data and needs real-data validation and a new model release. Manifest sha256 `9700b57b77db691a3697182ae2028aba6635dd22a86eda3135e2a4fc0c721d26`; results are in the ignored `.local/experiments/digiface/results/`. This is a SYNTHETIC BENCHMARK, not classroom accuracy; it does not measure real cameras, lighting or people, and real held-out recognition remains 1/6. Reproduce with `experiments/ml_accuracy/run_synthetic.py` (`prepare`, then `run --variant ... --run N`).

| Variant | Present students suggested (easy / medium / hard) | Wrong-present marks | Median / p95 per scene |
|---|---|---|---|
| Baseline | 22 / 60 (20 / 2 / 0) | 0 | ≈0.10 s / ≈0.18 s |
| Detector-only CLAHE | 22 / 60 (20 / 2 / 0) | 0 | ≈0.13 s / ≈0.22 s |
| Contrast filter | 18 / 60 (18 / 0 / 0) | 0 | ≈0.10 s / ≈0.18 s |
| Two-scale SCRFD | 24 / 60 (21 / 3 / 0) | 0 | ≈0.42 s / ≈0.56 s |

Interpretation: the quality gate, not detection or matching, limits recall on medium and hard scenes, and the safe lever for a demo is capture quality (faces large in frame, front lighting) plus multiple clips per session. Loosening the gate or thresholds would change the frozen profile and must be a separately benchmarked candidate.

## 10. Client-run real testing

The Model Test Console (`docs/MODEL_TEST_CONSOLE.md`) lets a nontechnical person enrol consenting volunteers and score six scenarios on the frozen model, producing a readable report. It is not a classroom-accuracy, liveness or capacity test.
