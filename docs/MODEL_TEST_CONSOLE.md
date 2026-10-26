# Model test console

A small page for a **non-technical person** to check the frozen face model with consenting
volunteers and see, in plain words, whether its suggestions match what really happened.

It tests the **ML model only**. It does not use logins, classes, Supabase, the API, Redis or
attendance records, and it never changes the frozen model, profile, thresholds or templates used by
the product demo. Volunteer face data is kept in a separate, encrypted test folder.

Client step-by-step (Windows): [CLIENT_MODEL_TEST_STEPS.md](CLIENT_MODEL_TEST_STEPS.md).

## What the client does

1. Open the page and read the **System check** (green means the model and settings are unchanged).
2. **Add volunteers** (2 minimum, 3 or more is better): enter a name or nickname, tick consent, record a
   15-second clip while the person follows the head-turn prompts, tick that you watched it, then save.
3. Do the **six recordings** (10 seconds each): everyone enrolled present, one enrolled person absent,
   only a stranger, enrolled person plus a stranger, different positions/distances, and an empty scene.
   For each, tick who is really visible, record, then press *Check this recording*.
4. Read the **Results**, press *Download report + summary* (two files: a readable `.txt` report and a `.json` data file; ask the client to send you both), and press *Delete all test data* when finished.

Each clip is deleted from the computer immediately after checking. Both downloaded files contain counts
only: no names, face data or videos.

## How results are scored

- A recording is **Matched** only if the model's suggested people are exactly the people the client
  ticked as visible. A wrongly suggested person is shown as a **false presence**; a visible person the
  model did not suggest is shown as **not recognised** (a miss; it never means "absent").
- Every recording is analysed **three times in separate fresh processes**. If the answers differ, the
  page warns that the result is unreliable.
- A scenario's **first scored attempt is its official result**. Retries and rejected recordings (too
  short, unreadable) are counted but never replace it, so results cannot be tuned by re-recording.
- This is six short recordings with a few volunteers in one room. It is **not** a classroom accuracy
  figure, a liveness test or a capacity test. The summary says so.

## Owner setup (once)

The bundle and model files are private and Git-ignored.

```sh
# macOS/Linux, from the repository root
scripts/build-console            # builds the page into .local/console-web
make console                     # Docker serves http://127.0.0.1:8010
make console-down                # stop; test data remains until deleted in the page
```

For the native verified-Mac path, first install `services/worker/.venv` with its locked Python 3.11 environment, then use `scripts/test-console` instead of Docker.

For a Windows client, add these to the encrypted private archive described in
`CLIENT_WINDOWS_HANDOFF.md`, in addition to the existing model and profile files:

```text
.local/console-web/              # output of scripts/build-console
```

The client does **not** need `services/api/.env`, `services/worker/.env` or `development.json` for this
page. They need Docker Desktop (see `WINDOWS_SETUP.md`), then in PowerShell from `C:\FaceTrack`:

```powershell
.\scripts\windows\start-console.ps1     # builds, starts and opens http://127.0.0.1:8010
.\scripts\windows\stop-console.ps1      # stop; data is kept until deleted on the page
```

Camera access works because `127.0.0.1` is treated as a secure origin by Chrome and Edge.

## Safety properties

- Listens on loopback only; rejects other `Host` and `Origin` headers; mutating calls need a custom
  header, so other web pages cannot drive it.
- Uploads are limited (25 MiB enrolment, 50 MiB test), WebM/MP4 only, deleted right after processing.
- Names are stored only in a private local file and are never exported.
- On first start it pins the model, profile and inference source hashes. If anything later changes,
  every step is blocked until the project owner investigates (delete `frozen-pin.json` only after
  reviewing why). Where the repository's held-out freeze receipt is present, it is checked too.
- Enrolment requires both the volunteer-consent and supervisor tick boxes, matching the existing
  `enrol --consent --supervised-pose-review` gate. Ordinary video is not liveness protection.

## Not verified yet

Automated tests use synthetic fixtures and mocked inference. Real camera recording, real volunteers and
Windows/Docker operation of this page still need one physical run before this is called accepted.
