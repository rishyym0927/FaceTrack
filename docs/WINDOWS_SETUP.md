# Run FaceTrack on Windows

This page is the Windows checklist. The full configuration and first-time Supabase instructions are in [INSTALLATION.md](INSTALLATION.md).

**Status:** Windows 10/11 x64 support is implemented, Docker images build, and both Compose files validate. A complete run on a physical Windows host is still pending. Windows on ARM is unverified.

## 1. Install once

Install:

1. Git for Windows.
2. Docker Desktop using the **WSL 2 Linux engine**. Keep Linux containers enabled.
3. Flutter stable compatible with Dart 3.13.5.
4. Chrome or Edge.
5. JDK 17 and Android platform tools only if building/running Android.

Open PowerShell and verify:

```powershell
git --version
docker compose version
docker info
flutter --version
flutter doctor
flutter devices
```

Docker Compose must be v2.20 or newer. Start Docker Desktop and wait until the Linux engine is ready.

## 2. Clone and prepare

```powershell
git clone https://github.com/rishyym0927/FaceTrack.git C:\FaceTrack
Set-Location C:\FaceTrack
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\windows\setup.ps1 -SkipContainerBuild
```

The script verifies Git, Flutter and Docker; creates ignored config templates when missing; and installs locked Flutter packages. Remove `-SkipContainerBuild` to build the Docker images immediately.

## 3. Add the private package

Copy the authorized package contents into `C:\FaceTrack` so these files exist:

```text
services\api\.env
services\worker\.env
.local\flutter\development.json
.local\spike\models\buffalo_sc\manifest.json
.local\spike\models\buffalo_sc\det_500m.onnx
.local\spike\models\buffalo_sc\w600k_mbf.onnx
.local\spike\profiles\frozen-phase1b-v1.json
```

Do not open or paste these files into chat. If no private package exists, follow the owner provisioning path in [INSTALLATION.md](INSTALLATION.md#5-first-time-owner-setup-with-a-new-supabase-project).

## 4. Start the complete application

```powershell
Set-Location C:\FaceTrack
.\scripts\windows\start-demo.ps1
```

Use `-Browser edge` if Chrome is unavailable. The script:

- starts Redis, API, worker and agent in Linux containers;
- waits for API readiness;
- verifies all four services remain running;
- starts Teacher web on port 5300 and Student web on port 5301 in separate PowerShell windows.

Expected readiness:

```powershell
(Invoke-RestMethod http://127.0.0.1:8000/health/ready).status
```

Expected output: `ready`.

Daily backend-only commands use the root launcher:

```powershell
.\run.ps1 up
.\run.ps1 health
.\run.ps1 ps
.\run.ps1 logs
.\run.ps1 down
```

Stop the complete demo with:

```powershell
.\scripts\windows\stop-demo.ps1
```

Close the two Flutter PowerShell windows separately.

## 5. Android phone

Enable USB debugging, connect and unlock the phone, then accept the authorization prompt:

```powershell
.\scripts\windows\android-connect.ps1
flutter devices
```

The helper restores port 8000 forwarding. Keep USB connected while the API is local. Do not reinstall an app while a recording is active.

## 6. Model-test console only

This mode does not need Supabase, API credentials or Flutter product configuration. It needs the private model/profile and a prebuilt `.local\console-web\index.html`.

```powershell
.\scripts\windows\start-console.ps1
.\scripts\windows\stop-console.ps1
```

See [MODEL_TEST_CONSOLE.md](MODEL_TEST_CONSOLE.md).

## 7. Troubleshooting

- **Scripts disabled:** run `Set-ExecutionPolicy -Scope Process Bypass` in the current PowerShell.
- **Docker pipe/daemon error:** start Docker Desktop and enable the WSL 2 Linux engine.
- **`include` unsupported:** update Docker Desktop/Compose, or run `docker compose -f compose.yaml up -d`.
- **API not ready:** run `docker compose -f compose.windows.yaml logs --tail 100 api` and check private configuration for missing files/placeholders without printing values.
- **Worker unauthorized:** the scoped token may be expired; contact the operator rather than regenerating it.
- **Flutter cannot find Chrome:** install Chrome or run `start-demo.ps1 -Browser edge`.
- **Android says connection unavailable:** reconnect USB and rerun `android-connect.ps1`.
- **Camera denied:** allow camera access for `http://localhost:5300` or `http://localhost:5301` in the browser settings.
- **Port conflict:** check ports 8000, 5300 and 5301 before stopping any unrelated process.

Use [CLIENT_WINDOWS_HANDOFF.md](CLIENT_WINDOWS_HANDOFF.md) when a nontechnical user wants an LLM with terminal access to perform these steps.
