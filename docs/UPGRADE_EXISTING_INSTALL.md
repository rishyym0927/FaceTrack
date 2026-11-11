# Upgrade an existing FaceTrack install and add the ML model

This guide is for a client who **already installed an older FaceTrack full application** on Windows (`C:\FaceTrack`) or macOS (`~/FaceTrack`) and is connected to Rishi's shared hosted Supabase project, but who **does not have the licensed model files**. Without those files the worker and agent cannot start, so no face processing happens.

The upgrade does three things:

1. updates the code to the latest version;
2. adds the model folder and frozen recognition profile from Rishi's encrypted archive;
3. keeps her existing configuration and all hosted data exactly as they are.

Nothing is reinstalled. Nothing in Supabase is changed. No migration, seed or provisioning is run. The hosted database is already at schema `0008_admin`, which the latest code expects.

It assumes the client uses **Claude Code** (or another Claude session with terminal and file access), like the [first-time client setup](CLIENT_SETUP.md). The human steps are below. The [copy-paste prompt for Claude Code](#prompt-to-copy-into-claude-code) is at the end.

> **Licence:** the InsightFace `buffalo_sc` model permission covers only this non-commercial academic experiment. The model files must never be committed, uploaded, emailed unencrypted or pasted into a chat.

## Owner checklist (Rishi, before sending)

1. **Confirm the target release is on `main`.** The update pulls the remote branch. Confirm its expected commit and database migration head before giving it to the recipient.
2. **Build the encrypted archive** with this structure. The ML part is required. The worker `.env` is optional (see step 4).

   ```text
   facetrack-ml-upgrade/
   ├── .local/
   │   └── spike/
   │       ├── models/buffalo_sc/                # whole folder
   │       │   ├── manifest.json
   │       │   ├── license-evidence.json         # the manifest's evidence_file
   │       │   ├── det_500m.onnx                 # 2,524,817 bytes
   │       │   └── w600k_mbf.onnx                # 13,616,099 bytes
   │       └── profiles/
   │           └── frozen-phase1b-v1.json        # only this profile
   └── services/worker/.env                      # OPTIONAL, only if renewed
   ```

   Copy the files exactly as they are on your machine. The worker credential only permits the model hash it was provisioned with, so the manifest and ONNX files must be byte-identical to yours. Do **not** include the `candidate-calibration-v*.json` profiles, recordings, templates, embeddings, or `services/api/.env`. She already has her own API configuration and it must not change.
3. **Send the archive password through a different channel** from the archive (for example, archive by file share and password by phone or a password manager).
4. **Check the worker credential.** `tools.provision_enrollment` creates the scoped worker token with a 30-day expiry (`now()+interval '30 days'`). If her `services/worker/.env` was issued more than about 30 days ago, or you are not sure, renew it through your operator procedure and include the new `services/worker/.env` in the archive. Renewal is outside the scope of this guide. `provision_enrollment` refuses to overwrite an existing worker `.env`, and the client must never run it.
5. **Tell her no migration is needed.** The hosted database is already at `0008_admin`. The client must not run Alembic, `tools.seed`, `tools.provision_*` or `tools.configure_*`.
6. **Agree who runs a backend during your demonstration** (see the caveat below).

## Caveat: two backends on one hosted project

Her backend and Rishi's backend both claim processing jobs from the same hosted database. Database leases keep this correct: only one worker holds a job at a time, and an expired lease holder cannot commit. However, the job may be processed on either computer, and timing becomes harder to predict. **While Rishi is demonstrating, run only one backend.** The client should stop hers (Windows `.\scripts\windows\stop-demo.ps1`, macOS `make down`) unless Rishi asks otherwise.

## Steps

The paths below use `C:\FaceTrack` (Windows) and `~/FaceTrack` (macOS). Use her real install folder if it is different. Do not print the contents of any private file at any step. Check names and sizes only.

### 1. Inspect the existing install

- Check whether the folder is a Git clone (it contains a `.git` folder) or was unpacked from a ZIP.
- **Git install:** run `git status` and `git rev-parse HEAD` in the folder. Write down the commit ID; it is the rollback point. If `git status` shows modified tracked files, **stop** and tell Rishi which files are listed. Do not discard them.
- **ZIP install:** there is no commit to record. Write down the ZIP's name or date. The old folder itself becomes the rollback copy.
- Check which private files exist, **by name only**:
  - `services/api/.env`
  - `services/worker/.env`
  - `.local/flutter/development.json`
  - `.local/spike/models/buffalo_sc/` and `.local/spike/profiles/frozen-phase1b-v1.json` (expected to be missing)

If `services/api/.env` or `.local/flutter/development.json` is missing, stop and contact Rishi. These cannot be recreated without breaking her link to the hosted data.

### 2. Back up the private files

Create a dated folder **outside** the repository, for example `C:\FaceTrack-backup-2026-10-27` or `~/FaceTrack-backup-2026-10-27`. Copy these into it, keeping their relative paths:

- `services/api/.env`
- `services/worker/.env` (if it exists)
- the whole `.local` folder

Windows PowerShell:

```powershell
$Backup = "C:\FaceTrack-backup-$(Get-Date -Format yyyy-MM-dd)"
New-Item -ItemType Directory -Force "$Backup\services\api", "$Backup\services\worker" | Out-Null
Copy-Item C:\FaceTrack\services\api\.env "$Backup\services\api\"
if (Test-Path C:\FaceTrack\services\worker\.env) { Copy-Item C:\FaceTrack\services\worker\.env "$Backup\services\worker\" }
Copy-Item -Recurse C:\FaceTrack\.local "$Backup\.local"
```

macOS Terminal:

```sh
BACKUP=~/FaceTrack-backup-$(date +%F)
mkdir -p "$BACKUP/services/api" "$BACKUP/services/worker"
cp -p ~/FaceTrack/services/api/.env "$BACKUP/services/api/"
[ -f ~/FaceTrack/services/worker/.env ] && cp -p ~/FaceTrack/services/worker/.env "$BACKUP/services/worker/"
cp -Rp ~/FaceTrack/.local "$BACKUP/.local"
```

Confirm that the backup files exist and have the same sizes as the originals.

### 3. Stop the running services

- **Windows:** in `C:\FaceTrack`, run `Set-ExecutionPolicy -Scope Process Bypass`, then `.\scripts\windows\stop-demo.ps1`. Close the two Flutter PowerShell windows (Teacher and Student).
- **macOS:** in `~/FaceTrack`, run `make down`. Press `q` or close the two Terminal windows running Flutter.

Use plain `down` only. **Never** add `-v`. Removing volumes is never part of this upgrade.

### 4. Update the code

**Git install:**

```sh
git fetch origin
git switch main
git pull --ff-only
```

If `git switch` or `git pull --ff-only` refuses because of local changes or a diverged branch, **stop** and report the message. Do not reset, stash, force or delete anything.

**ZIP install:**

1. Extract the new ZIP **beside** the old folder (for example `C:\FaceTrack-new`). Do not extract over the old folder.
2. Copy the private files from the step 2 backup into the new folder at the same paths: `services/api/.env`, `services/worker/.env` (if present) and the whole `.local` folder.
3. Rename the old folder (for example to `C:\FaceTrack-old`) and rename the new folder to `C:\FaceTrack` (macOS: `~/FaceTrack-old` and `~/FaceTrack`). Keep the old folder as the rollback copy.

Before going further, confirm that `services/api/.env` and `.local/flutter/development.json` exist in the updated folder. The Windows `setup.ps1` script (step 6) **creates a new `services/api/.env` with a new join-code key if the file is missing**, and that key would not match her hosted data.

### 5. Install the ML files from the encrypted archive

1. Save the encrypted archive outside the repository. Enter its password only in the extraction tool, never in a chat.
2. Extract it to a temporary folder **outside** the repository.
3. Copy the contents into the repository root so these paths exist:

   ```text
   .local/spike/models/buffalo_sc/manifest.json
   .local/spike/models/buffalo_sc/license-evidence.json
   .local/spike/models/buffalo_sc/det_500m.onnx
   .local/spike/models/buffalo_sc/w600k_mbf.onnx
   .local/spike/profiles/frozen-phase1b-v1.json
   ```

4. If the archive includes `services/worker/.env`, it is a renewed credential from Rishi. Copy it over the old one; the old one is already in the backup. If it does not, keep her existing file.
5. Verify by name and size only. `det_500m.onnx` should be 2,524,817 bytes and `w600k_mbf.onnx` 13,616,099 bytes. The load check in step 8 verifies the exact hashes.
6. **Git install only:** confirm Git ignores every private file. Each path must be printed back:

   ```sh
   git check-ignore services/api/.env services/worker/.env .local/flutter/development.json .local/spike/models/buffalo_sc/manifest.json .local/spike/models/buffalo_sc/w600k_mbf.onnx .local/spike/profiles/frozen-phase1b-v1.json
   ```

7. Delete the unencrypted temporary extraction folder. The client decides whether to keep the encrypted archive.

### 6. Refresh dependencies and rebuild images

**Windows** (in `C:\FaceTrack`):

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\windows\setup.ps1 -SkipContainerBuild
```

This installs the locked Flutter packages for both apps. The image rebuild happens in step 7, because `start-demo.ps1` builds unless it is given `-NoBuild`.

**macOS** (system Flutter, run in each app folder):

```sh
cd ~/FaceTrack/apps/teacher && flutter pub get --enforce-lockfile
cd ~/FaceTrack/apps/student && flutter pub get --enforce-lockfile
cd ~/FaceTrack && make build
```

`make build` is required. `make up` alone does **not** rebuild, and would run the old images. If `make` is not available on the Mac, use the equivalent `docker compose build`, `docker compose up -d` and `docker compose down`. Do not use `scripts/setup.sh` for this upgrade. Like `setup.ps1`, it creates config files when they are missing.

### 7. Start FaceTrack

**Windows:**

```powershell
.\scripts\windows\start-demo.ps1
```

Use `-Browser edge` if Chrome is unavailable. The script checks the private files, builds and starts the four containers, waits for readiness and opens Teacher (port 5300) and Student (port 5301) in two PowerShell windows.

**macOS:** start the backend, then the two apps in two separate Terminal windows (commands from [INSTALLATION.md](INSTALLATION.md)):

```sh
cd ~/FaceTrack && make up
```

```sh
cd ~/FaceTrack/apps/teacher
../../scripts/flutter run -d chrome --web-hostname localhost --web-port 5300 --dart-define-from-file=../../.local/flutter/development.json
```

```sh
cd ~/FaceTrack/apps/student
../../scripts/flutter run -d chrome --web-hostname localhost --web-port 5301 --dart-define-from-file=../../.local/flutter/development.json
```

`scripts/flutter` uses the system Flutter when the bundled `.tools` toolchain is absent.

### 8. Verify the ML without using any face data

1. **API readiness:** `curl -fsS http://127.0.0.1:8000/health/ready` (Windows: `(Invoke-RestMethod http://127.0.0.1:8000/health/ready).status`) returns `ready`.
2. **Four containers running:** `docker compose ps` (Windows: `docker compose -f compose.windows.yaml ps`) shows `redis`, `api`, `worker` and `agent` running, and not restarting.
3. **No configuration errors in the logs:** `docker compose logs --tail 100 worker agent` (Windows: add `-f compose.windows.yaml` after `compose`) contains none of:
   - `Configure the scoped local worker first.`
   - `Worker API must use HTTPS or local loopback.`
   - `This milestone uses a private local Redis broker.`
   - `MODEL_PERMISSION_REQUIRED`, `LICENSE_EVIDENCE_MISMATCH`, `MODEL_HASH_MISMATCH`, `PROFILE_MODEL_MISMATCH`
   - `401`, `403` or "unauthorized" / "expired" (an expired worker credential: contact Rishi)
4. **Model and profile load check** inside the worker container. It reads only the model files and profile, not any face data, and prints one line:

   ```sh
   docker compose exec worker /opt/venv/bin/python -c "from pathlib import Path; from facetrack_ml.config import load_manifest, load_profile, canonical_hash; m = load_manifest(Path('/workspace/.local/spike/models/buffalo_sc/manifest.json')); load_profile(Path('/workspace/.local/spike/profiles/frozen-phase1b-v1.json'), canonical_hash(m.model_dump())); print('model and profile OK')"
   ```

   On Windows, use `docker compose -f compose.windows.yaml exec worker ...` with the same Python text. Expected output: `model and profile OK`. Any other output names the problem, for example `MODEL_HASH_MISMATCH` means a model file is missing or different from Rishi's copy.

### 9. Functional check (the client does this herself)

- Open Teacher at `http://localhost:5300` and Student at `http://localhost:5301`.
- The client types her own demo passwords directly into the apps. Never paste them into a chat.
- Check that the Teacher and Student subject lists load, and that the faculty dashboard shows overall, semester-wise and subject-wise attendance. Use read-only navigation only. Claude must not create sessions, record faces, accept consent, approve enrolments, publish attendance or rotate join codes for her.

### 10. Rollback (only if the upgrade fails)

1. Stop the services (step 3).
2. **Git install:** `git switch --detach <recorded commit ID>`. **ZIP install:** rename the folders back so the old folder is `C:\FaceTrack` / `~/FaceTrack` again.
3. Copy the files back from the step 2 backup (`services/api/.env`, `services/worker/.env`, `.local`).
4. Rebuild and start the old version: Windows `.\scripts\windows\start-demo.ps1`; macOS `make build`, then `make up`.

**Rollback restores her files and code, not necessarily a working API.** The API checks that the database schema head matches the version its code expects. Older code that expects `0007_attendance_queries` reports `NOT_READY` against the hosted database, which is now at `0008_admin`. Her old install may already have been in this state. If the upgrade fails, the safer action is usually to report the error to Rishi rather than roll back.

## Prompt to copy into Claude Code

Give the assistant the checkout path and the location of the encrypted archive.
Ask it to follow this guide from the start, report failed checks, and leave
credentials and hosted data untouched. Enter archive and account passwords
directly in the extraction tool or app.

## Related guides

- [Installation and configuration reference](INSTALLATION.md)
- [Windows checklist](WINDOWS_SETUP.md)
- [First-time client setup (Windows and macOS)](CLIENT_SETUP.md)
- [Model-test console only](MODEL_TEST_CONSOLE.md)
