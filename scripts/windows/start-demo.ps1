[CmdletBinding()]
param(
    [ValidateSet("chrome", "edge")][string]$Browser = "chrome",
    [switch]$BackendOnly,
    [switch]$NoBuild
)

$ErrorActionPreference = "Stop"
$Root = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
Set-Location $Root

$RequiredFiles = @(
    "services/api/.env",
    "services/worker/.env",
    ".local/flutter/development.json",
    ".local/spike/models/buffalo_sc/manifest.json",
    ".local/spike/profiles/frozen-phase1b-v1.json"
)
foreach ($Relative in $RequiredFiles) {
    if (-not (Test-Path (Join-Path $Root $Relative))) {
        throw "Missing private configuration: $Relative. Follow docs/WINDOWS_SETUP.md."
    }
}
if (Select-String -Quiet -Path "services/api/.env", ".*REPLACE.*|not-configured") {
    throw "services/api/.env still contains placeholders. Complete it before startup."
}
if (Select-String -Quiet -Path ".local/flutter/development.json", ".*REPLACE.*") {
    throw ".local/flutter/development.json still contains placeholders."
}
if (Select-String -Quiet -Path "services/worker/.env", ".*REPLACE.*") {
    throw "services/worker/.env still contains placeholders; provision the worker first."
}

$ComposeArgs = @("compose", "-f", "compose.windows.yaml", "up", "-d")
if (-not $NoBuild) { $ComposeArgs += "--build" }
& docker @ComposeArgs
if ($LASTEXITCODE -ne 0) { throw "Container startup failed. Run docker compose -f compose.windows.yaml logs." }

$Ready = $false
for ($Attempt = 0; $Attempt -lt 40; $Attempt++) {
    try {
        $Response = Invoke-RestMethod "http://127.0.0.1:8000/health/ready" -TimeoutSec 2
        if ($Response.status -eq "ready") { $Ready = $true; break }
    } catch { Start-Sleep -Seconds 2 }
}
if (-not $Ready) {
    docker compose -f compose.windows.yaml ps
    throw "API did not become ready. Inspect: docker compose -f compose.windows.yaml logs api"
}
$ExpectedServices = @("redis", "api", "worker", "agent")
$AllRunning = $false
for ($Attempt = 0; $Attempt -lt 20; $Attempt++) {
    $Running = @(& docker compose -f compose.windows.yaml ps --status running --services)
    $Missing = @($ExpectedServices | Where-Object { $_ -notin $Running })
    if ($Missing.Count -eq 0) { $AllRunning = $true; break }
    Start-Sleep -Seconds 1
}
if (-not $AllRunning) {
    docker compose -f compose.windows.yaml ps
    throw "One or more services stopped. Inspect: docker compose -f compose.windows.yaml logs --tail 100"
}
Write-Host "Backend ready at http://127.0.0.1:8000" -ForegroundColor Green
if ($BackendOnly) { return }

$Devices = (& flutter devices 2>&1 | Out-String)
if ($Devices -notmatch "(?im)\b$Browser\b.*web-javascript") {
    throw "Flutter cannot see '$Browser'. Run 'flutter devices' and use -Browser chrome or edge."
}

$Config = Join-Path $Root ".local/flutter/development.json"
function Start-FlutterApp([string]$Name, [string]$Directory, [int]$Port) {
    $LaunchDir = Join-Path $Root ".local/windows"
    New-Item -ItemType Directory -Force $LaunchDir | Out-Null
    $LaunchFile = Join-Path $LaunchDir ("start-" + $Name.ToLowerInvariant() + ".ps1")
    $Body = @"
Set-Location '$($Directory.Replace("'", "''"))'
flutter run -d $Browser --web-hostname localhost --web-port $Port --dart-define-from-file='$($Config.Replace("'", "''"))'
"@
    [IO.File]::WriteAllText($LaunchFile, $Body, [Text.UTF8Encoding]::new($false))
    Start-Process powershell.exe -ArgumentList "-NoExit -ExecutionPolicy Bypass -File `"$LaunchFile`""
}

Start-FlutterApp "Teacher" (Join-Path $Root "apps/teacher") 5300
Start-FlutterApp "Student" (Join-Path $Root "apps/student") 5301
Write-Host "Opening Teacher on 5300 and Student on 5301. Keep both PowerShell windows open." -ForegroundColor Green
