# FaceTrack first-time setup for a nontechnical user (Windows or macOS)

If you already have a sign-in and only want to use the hosted website or install the Android APK, follow the [user guide](USER_GUIDE.md). The steps below are for running a local copy from the repository.

This guide is for an **authorized local backend install**, optionally assisted by a terminal-enabled coding assistant. If FaceTrack is already installed and only needs updating, use [the upgrade guide](UPGRADE_EXISTING_INSTALL.md) instead.

Local development uses the owner's hosted Supabase project with Flutter web and Linux service containers on the developer's machine. Coordinate worker ownership before starting the local worker and agent.

## What Rishi must send separately

The repository excludes credentials and licensed model files. Share backend configuration only with authorized operators who need to run the local stack. Send one encrypted archive through a private channel, and its password through a different channel. The archive must keep this structure:

```text
facetrack-private-config/
├── services/api/.env
├── services/worker/.env
└── .local/
    ├── flutter/development.json
    └── spike/
        ├── models/buffalo_sc/            # entire directory: manifest, licence evidence, two .onnx files
        └── profiles/frozen-phase1b-v1.json
```

Send the Student and Teacher login details separately through a password manager or another private channel. Never put passwords, `.env` contents, model files, recordings or templates into GitHub or an AI chat message.

The worker credential is time-limited. Contact the operator if it is expired or rejected. The operator owns schema, provisioning and credential changes to the shared project.

## Prompt to copy into Claude Code

Copy everything inside this block:

```text
You are setting up and running the FaceTrack academic demonstration on my computer for the first time. I am nontechnical, so perform the terminal and file operations yourself, explain only the actions I must take, and verify every step before continuing.

Repository: https://github.com/rishyym0927/FaceTrack.git

Rules:
1. Detect the operating system first. On Windows use PowerShell and the scripts in scripts\windows. On macOS use Terminal (zsh) and the Makefile. Do not mix them.
2. Read AGENTS.md, README.md, docs/INSTALLATION.md and PROGRESS.md before acting. On Windows also read docs/WINDOWS_SETUP.md.
3. Do not modify application code, database schema, model settings, attendance records or Supabase data to make setup pass.
4. Never display, print, upload or commit .env files, tokens, passwords, model files, recordings, embeddings or templates.
5. Do not run seed, migration, provisioning, key-rotation or model-download commands. The shared project is already set up.
6. Do not accept biometric consent, record a face, approve a template or publish attendance for me.
7. If private configuration is missing or expired, stop and tell me exactly which file or error to send to Rishi. Do not invent values.

Do this in order:

A. Inspect the computer
- Windows: confirm Windows 10/11 x64 (not ARM) with virtualization available. macOS: confirm the macOS version and whether it is Apple Silicon or Intel.
- Check free disk space (at least 15 GB) and whether Git, Flutter stable, Docker Desktop (on Windows with WSL 2), and Chrome or Edge are installed.
- Run `flutter doctor`, `flutter devices`, `docker version` and `docker info` where available.
- Install anything missing from its official source. On Windows prefer winget only after verifying the package ID with `winget search`; on macOS use the official installers. Ask me only when the system needs administrator approval, a restart, licence acceptance, sign-in or a physical USB action.
- Keep Docker Desktop in Linux-container mode.

B. Prepare the repository
- Windows: clone to `C:\FaceTrack`. macOS: clone to `~/FaceTrack`. If the folder already exists, inspect `git status` first, do not delete anything, and stop: this may be an existing install that needs docs/UPGRADE_EXISTING_INSTALL.md instead.
- Windows: run `Set-ExecutionPolicy -Scope Process Bypass`, then `.\scripts\windows\setup.ps1 -SkipContainerBuild`.
- macOS: run `scripts/setup.sh --skip-build`.
- If setup fails, diagnose the specific prerequisite or command. Do not bypass its checks.

C. Install the private configuration
- Ask me to select the encrypted `facetrack-private-config` archive and to type its password only into the extraction program.
- Copy its CONTENTS into the repository root, replacing the template files setup created, so these paths exist:
  - services/api/.env
  - services/worker/.env
  - .local/flutter/development.json
  - .local/spike/models/buffalo_sc/manifest.json (plus the other files in that folder)
  - .local/spike/profiles/frozen-phase1b-v1.json
- Do not show the contents. Check only that the files exist, are non-empty and are ignored by Git with `git check-ignore`.
- Delete any unencrypted staging copy outside the repository when finished. Let me keep or delete the encrypted archive.

D. Start and verify FaceTrack
- Make sure Docker Desktop is running.
- Windows: run `.\scripts\windows\start-demo.ps1` (add `-Browser edge` only if Chrome is unavailable). It builds and starts the containers and opens both apps.
- macOS: run `make build`, then `make up` (without make: `docker compose build`, then `docker compose up -d`). Then start the two apps in two separate Terminal windows:
  - in apps/teacher: `../../scripts/flutter run -d chrome --web-hostname localhost --web-port 5300 --dart-define-from-file=../../.local/flutter/development.json`
  - in apps/student: `../../scripts/flutter run -d chrome --web-hostname localhost --web-port 5301 --dart-define-from-file=../../.local/flutter/development.json`
- Wait until all four containers are running: api, redis, worker and agent (`docker compose ps`).
- Verify `http://127.0.0.1:8000/health/ready` returns ready.
- Verify Teacher opens at http://localhost:5300 and Student at http://localhost:5301.
- Ask me to type the login passwords directly into the apps. Never ask me to paste passwords into this chat.
- Check that the Teacher subject list and the Student subject list load. Use read-only navigation only: do not create sessions, change attendance, record faces or rotate join codes.

E. Troubleshooting
- Service failure: `docker compose ps` and `docker compose logs --tail 100 api worker agent redis`.
- Expired or unauthorized worker credential: stop and tell me to contact Rishi.
- Ports 8000, 5300 or 5301 already in use: find the process and ask before stopping anything unrelated.
- Camera permission denied: guide me through the system and browser camera settings. Do not weaken app security.

Completion report:
A short table showing Git, Flutter/browser, Docker, private-file presence, API readiness, the four container states, Teacher web and Student web as Passed or Failed. List any manual action still required. Do not claim acceptance unless every check actually passed.
```

## Daily start after the first setup

Give Claude this shorter prompt on later days:

```text
Open my FaceTrack folder (C:\FaceTrack on Windows, ~/FaceTrack on macOS). Read docs/INSTALLATION.md. Start Docker Desktop if needed. On Windows run `.\scripts\windows\start-demo.ps1`. On macOS run `make up`, then start the Teacher app on port 5300 and the Student app on port 5301 with the flutter run commands in docs/INSTALLATION.md section 4. Verify all four containers, API readiness, Teacher on 5300 and Student on 5301. Do not change code, configuration, database data, biometrics or attendance. If a private credential is missing or expired, stop and tell me to contact Rishi without printing the credential.
```

To stop: Windows `.\scripts\windows\stop-demo.ps1`; macOS `make down`. Then close the two Flutter windows. If `make` is not available on the Mac, use the equivalent `docker compose build`, `docker compose up -d` and `docker compose down`.

## Model test only (no application login)

To run only the Model Test Console, follow [MODEL_TEST_CONSOLE.md](MODEL_TEST_CONSOLE.md). It needs Docker, the repository, the private model and frozen profile files (`.local/spike/models/buffalo_sc/` and `.local/spike/profiles/frozen-phase1b-v1.json`) and the built page (`.local/console-web/`). It does not need either `.env` file or `development.json`. After testing, the tester sends back the two downloaded files (`facetrack-model-test-report.txt` and `facetrack-model-test.json`), which contain counts only.
