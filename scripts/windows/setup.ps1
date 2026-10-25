[CmdletBinding()]
param([switch]$SkipContainerBuild)

$ErrorActionPreference = "Stop"
$Root = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
Set-Location $Root

function Require-Command([string]$Name, [string]$Help) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Missing '$Name'. $Help"
    }
}

Require-Command "git" "Install Git for Windows, then reopen PowerShell."
Require-Command "flutter" "Install Flutter stable and add its bin folder to PATH."
Require-Command "docker" "Install Docker Desktop and enable Linux containers."

docker info *> $null
if ($LASTEXITCODE -ne 0) {
    throw "Docker Desktop is not running. Start it and wait for the Linux engine."
}

$FlutterConfig = Join-Path $Root ".local/flutter/development.json"
if (-not (Test-Path $FlutterConfig)) {
    New-Item -ItemType Directory -Force (Split-Path $FlutterConfig) | Out-Null
    Copy-Item (Join-Path $Root "config/flutter.development.example.json") $FlutterConfig
    Write-Host "Created .local/flutter/development.json — fill its public Supabase values." -ForegroundColor Yellow
}

$ApiEnv = Join-Path $Root "services/api/.env"
if (-not (Test-Path $ApiEnv)) {
    $Template = Get-Content (Join-Path $Root "services/api/.env.example") -Raw
    $KeyBytes = New-Object byte[] 32
    $Generator = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $Generator.GetBytes($KeyBytes) } finally { $Generator.Dispose() }
    $JoinKey = ([BitConverter]::ToString($KeyBytes)).Replace("-", "").ToLowerInvariant()
    $Template = $Template.Replace("REPLACE_WITH_64_HEX_DIGITS", $JoinKey)
    [IO.File]::WriteAllText($ApiEnv, $Template, [Text.UTF8Encoding]::new($false))
    Write-Host "Created services/api/.env — fill its private database and Supabase values." -ForegroundColor Yellow
}

Push-Location (Join-Path $Root "apps/student")
flutter pub get --enforce-lockfile
Pop-Location
Push-Location (Join-Path $Root "apps/teacher")
flutter pub get --enforce-lockfile
Pop-Location

if (-not $SkipContainerBuild) {
    docker compose -f compose.windows.yaml build
}

Write-Host "Windows tools are ready." -ForegroundColor Green
Write-Host "Next: complete the ignored configuration described in docs/WINDOWS_SETUP.md, then run scripts/windows/start-demo.ps1."
