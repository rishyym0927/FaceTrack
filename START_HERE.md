# FaceTrack: start here (model testing)

This page is for someone who wants to **test the face-recognition model** without setting up the full app. There are two ways:

1. **Live testing with real people:** a simple local web page where you enrol a few consenting volunteers and check whether the model recognises them. No login is needed.
2. **Synthetic testing:** scripted tests on generated faces that report recall, false presence and speed.

The repository also contains the complete application (Teacher and Student apps and the backend). The login-based app needs private accounts and keys that are **not** public; see [docs/INSTALLATION.md](docs/INSTALLATION.md) or, for a nontechnical install done by Claude Code, [docs/CLIENT_SETUP.md](docs/CLIENT_SETUP.md).

---

## What you need

- **Docker Desktop** (Windows/macOS) or **Docker Engine** (Linux), showing **Running**. This is all you need for the live test page.
- The **private model-test files** from Rishi, sent separately in an encrypted archive:
  - `.local/spike/models/buffalo_sc/manifest.json` and `license-evidence.json`
  - `.local/spike/profiles/frozen-phase1b-v1.json`
  - `.local/console-web/` (the built test page)
- *(Synthetic tests only)* **Python 3.11**, `uv` and the DigiFace dataset; see the last section.

The two face-model weight files are **not** in the archive. They are licensed for non-commercial research and are not redistributed; Step 2 downloads them from the official source.

---

## Step 1: Get the project and the private files

Download or clone the repository into a simple folder, e.g. `C:\FaceTrack` (Windows) or `~/FaceTrack` (macOS/Linux), and open a terminal or PowerShell **in that folder**. Extract the private archive into the same folder so `.local` sits next to `scripts`. Type the archive password only into the extraction program.

## Step 2: Download the model weights (one command)

- **Windows:** `.\scripts\fetch-model.ps1`
- **macOS/Linux:** `scripts/fetch-model.sh`

This downloads InsightFace's official `buffalo_sc` release (about 15 MB), checks its checksum, and places `det_500m.onnx` and `w600k_mbf.onnx` beside the private `manifest.json`. When it says **Model ready**, continue.

## Step 3: Start the live model test page

- **Windows:** `.\run.ps1 console` (or `.\scripts\windows\start-console.ps1`, which also opens the browser)
- **macOS/Linux:** `make console` (or `docker compose --profile console up -d console`)

The first start builds for a few minutes. Then open **http://127.0.0.1:8010** in Chrome or Edge. The **System check** must be green ("Model and settings are unchanged"). If it says to stop and contact the project owner, stop and message Rishi.

To stop later: `.\run.ps1 console-down` (Windows) or `make console-down`. Volunteer data is kept until you press **Delete all test data** on the page.

## Step 4: Test with real volunteers

Enrol 2–3 consenting adults (a short guided clip each), run the six short test recordings, then press **Download report + summary**. The report contains counts only: no names, faces or videos. Step-by-step instructions and what the results mean: [docs/CLIENT_MODEL_TEST_STEPS.md](docs/CLIENT_MODEL_TEST_STEPS.md) and [docs/MODEL_TEST_CONSOLE.md](docs/MODEL_TEST_CONSOLE.md).

---

## Optional: synthetic tests (no people needed)

These need **Python 3.11**, `uv` and the DigiFace dataset. DigiFace is large and licensed: download it yourself from Microsoft DigiFace-1M and place `p1_72.zip` at `.local/experiments/digiface/p1_72.zip`. The model weights from Step 2 and the private profile are also required. From the project folder:

```sh
# set up the worker environment once (uses the lockfiles in the repo)
uv sync --project services/worker --locked --python 3.11

# classroom simulation (faces at different seat distances)
services/worker/.venv/bin/python -m experiments.ml_accuracy.run_classroom \
  --zip .local/experiments/digiface/p1_72.zip --out .local/experiments/classroom

# steady "teacher walks around with a phone" simulation, class of 70
services/worker/.venv/bin/python -m experiments.ml_accuracy.run_phone_walk \
  --zip .local/experiments/digiface/p1_72.zip --out .local/experiments/phonewalk \
  --present 70 --frames 210 --steady --face-cap 180 --dwell 4
```

Each prints recall, false-presence and identity-confusion numbers. They are a **synthetic benchmark**, not real classroom accuracy. Current figures are in [PROGRESS.md](PROGRESS.md).

---

## If something goes wrong

- Make sure Docker says **Running** before Step 3.
- If the page doesn't open, run the Step 3 command again and check `docker compose --profile console logs console`.
- Camera blocked in the browser: click the camera icon in the address bar and choose **Allow**.
- Missing-file errors: check that the private archive was extracted into the project folder and Step 2 finished.

Questions: ask Rishi. What the system can and cannot claim today is listed under **Current status** in [README.md](README.md).
