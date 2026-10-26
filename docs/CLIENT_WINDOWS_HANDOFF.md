# FaceTrack Windows handoff for a nontechnical user

This handoff assumes the client uses **Claude Code or another Claude session with terminal and file access**. A normal browser chat cannot install software or run the repository.

## What Rishi must send separately

The public repository intentionally excludes credentials and licensed model files. Send the client one encrypted archive through a private channel, with its password through a different channel. The archive must preserve this structure:

```text
facetrack-private-config/
├── services/api/.env
├── services/worker/.env
└── .local/
    ├── flutter/development.json
    └── spike/
        ├── models/buffalo_sc/            # entire directory
        └── profiles/frozen-phase1b-v1.json
```

Send the controlled Student and Teacher demo login details separately through a password manager or another private channel. Never put passwords, `.env` contents, model files, recordings or templates into GitHub or an AI chat message.

The worker credential expires. If processing returns an authorization/expired-worker error, the client must contact Rishi. They must not seed, migrate, rotate keys or reprovision the shared project themselves.

## Prompt to copy into Claude Code on Windows

Copy everything inside the following block:

```text
You are setting up and running the FaceTrack academic demonstration on my Windows laptop. I am nontechnical, so perform the terminal and file operations yourself, explain only the user actions I must take, and verify every step before continuing.

Repository: https://github.com/rishyym0927/FaceTrack.git

Rules:
1. Use Windows PowerShell. Do not use macOS commands from the README.
2. Read AGENTS.md, README.md, docs/INSTALLATION.md, docs/WINDOWS_SETUP.md and PROGRESS.md before acting.
3. Preserve the existing architecture. Do not modify application code, database schema, model settings, attendance records or Supabase data merely to make setup pass.
4. Never display, print, upload or commit .env files, tokens, passwords, model files, recordings, embeddings or templates.
5. Do not run seed, migration, provisioning, key-rotation or model-download commands for the existing demo.
6. Do not accept biometric consent, record a face, approve a template or publish attendance for me.
7. If private configuration is missing or expired, stop and tell me exactly which file/error must be sent to Rishi. Do not invent values.

Goal:
Run the complete existing FaceTrack demo locally: Supabase remains hosted; Flutter Student and Teacher apps run on Windows; FastAPI, Redis, Celery and the ML worker run through Docker Desktop Linux containers.

Do this in order:

A. Inspect the computer
- Confirm this is Windows 10/11 x64 (AMD64/Intel 64) with virtualization available. Stop and report if it is Windows on ARM because that host is unverified.
- Check free disk space and whether Git, Flutter stable, Docker Desktop, WSL 2, Chrome or Edge, and Android platform-tools are installed.
- Run `flutter doctor`, `flutter devices`, `docker version` and `docker info` where available.
- If a prerequisite is missing, install it from its official source. Prefer winget only after verifying the current package ID with `winget search`. Ask me only when Windows needs administrator approval, a Docker/WSL restart, license acceptance, sign-in or a physical USB action.
- Configure Docker Desktop to use the WSL 2/Linux container engine. Do not switch to Windows containers.

B. Prepare the repository
- Clone the repository to `C:\FaceTrack` if it is not already present. If it exists, inspect `git status` first and do not delete local work.
- Open PowerShell in the repository root.
- Run `Set-ExecutionPolicy -Scope Process Bypass`.
- Run `.\scripts\windows\setup.ps1`.
- If setup fails, diagnose the specific prerequisite or command. Do not bypass its security/configuration checks.

C. Install the private configuration
- Ask me to select the locally downloaded encrypted `facetrack-private-config` archive and enter its password privately when the extraction tool requests it.
- Extract/copy its CONTENTS into `C:\FaceTrack` so these exact paths exist:
  - `C:\FaceTrack\services\api\.env`
  - `C:\FaceTrack\services\worker\.env`
  - `C:\FaceTrack\.local\flutter\development.json`
  - `C:\FaceTrack\.local\spike\models\buffalo_sc\manifest.json`
  - `C:\FaceTrack\.local\spike\profiles\frozen-phase1b-v1.json`
- Do not show the contents. Check only that files exist, are non-empty and remain Git-ignored with `git check-ignore`.
- Never copy the private archive into the repository after extraction. Delete the unencrypted extracted staging folder outside the repository when finished; let me retain or delete the encrypted archive.

D. Start and verify FaceTrack
- Ensure Docker Desktop is running.
- From `C:\FaceTrack`, run `.\scripts\windows\start-demo.ps1`. Use `-Browser edge` only if Chrome is unavailable.
- Wait for all four containers: api, redis, worker and agent.
- Verify `http://127.0.0.1:8000/health/ready` returns ready.
- Verify Teacher opens at `http://localhost:5300` and Student at `http://localhost:5301`.
- Ask me to enter the provided demo passwords directly into the applications. Never request that I paste passwords into this chat.
- Verify the Teacher class list and Student class list load. Use only read-only navigation; do not create sessions, alter attendance, record biometrics or rotate join codes.

E. Optional Android phone
- Only if I ask for phone testing: have me enable USB debugging, connect and unlock the phone, and accept its authorization prompt.
- Run `.\scripts\windows\android-connect.ps1`, then `flutter devices`.
- Do not reinstall or restart an app while a recording is active.

F. Troubleshooting
- For service failure, inspect `docker compose -f compose.windows.yaml ps` and `docker compose -f compose.windows.yaml logs --tail 100 api worker agent redis`.
- Do not include secrets in your summary.
- If the worker reports an expired/unauthorized credential, stop and tell me to contact Rishi.
- If ports 8000, 5300 or 5301 are occupied, identify the process and ask before stopping anything unrelated.
- If camera permission is denied, guide me through Windows/browser permission settings; do not weaken app security.

Completion report:
Give me a short table showing Git, Flutter/browser, Docker/WSL, private-file presence, API readiness, four container states, Teacher web and Student web as Passed/Failed. List any manual action still required. Do not claim Windows acceptance unless all runtime checks actually passed.
```

## Daily start after first setup

The client can give Claude this shorter prompt on later days:

```text
Open C:\FaceTrack, read docs/INSTALLATION.md and docs/WINDOWS_SETUP.md, start Docker Desktop if needed, then run `.\scripts\windows\start-demo.ps1`. Verify all four containers, API readiness, Teacher on port 5300 and Student on port 5301. Do not change code, configuration, database data, biometrics or attendance. If a private credential is missing/expired, stop and tell me to contact Rishi without printing the credential.
```

Stop services with `C:\FaceTrack\scripts\windows\stop-demo.ps1` and close the two Flutter PowerShell windows.

## Model test only (no application login)

To run only the Model Test Console, follow `docs/MODEL_TEST_CONSOLE.md`. The client needs Docker Desktop, the repository, the private model and frozen profile files (`.local/spike/models/buffalo_sc/` and `.local/spike/profiles/frozen-phase1b-v1.json`) and the built page (`.local/console-web/`). She does not need `services/api/.env`, `services/worker/.env` or `development.json`. Model files must not be placed in the public repository. After testing she sends back the two downloaded files (`facetrack-model-test-report.txt` and `facetrack-model-test.json`), which contain counts only.
