# Cross-platform convenience verbs over `docker compose` for Windows.
# Mirrors the Makefile so every OS uses the same words. Docker Desktop is the
# only requirement for these backend/console verbs; product web apps also need
# Flutter. `docker compose ...` directly always works too.
#
#   ./run.ps1 up            start redis + api + worker + agent (detached)
#   ./run.ps1 down          stop and remove the stack
#   ./run.ps1 logs          follow logs for all services
#   ./run.ps1 ps            show service status
#   ./run.ps1 build         (re)build the api/worker images
#   ./run.ps1 console       start the model-test page on http://127.0.0.1:8010
#   ./run.ps1 console-down  stop the model-test page (volunteer data is kept)
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('up', 'down', 'logs', 'ps', 'build', 'restart', 'health', 'console', 'console-down')]
    [string]$Command = 'up'
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Root

switch ($Command) {
    'up'           { docker compose up -d; Write-Host 'Stack starting. Readiness: http://127.0.0.1:8000/health/ready' }
    'down'         { docker compose down }
    'logs'         { docker compose logs -f }
    'ps'           { docker compose ps }
    'build'        { docker compose build }
    'restart'      { docker compose down; docker compose up -d }
    'health'       { try { (Invoke-WebRequest -UseBasicParsing 'http://127.0.0.1:8000/health/ready' -TimeoutSec 3).Content } catch { 'API not reachable yet' } }
    'console'      { docker compose --profile console up -d console; Write-Host 'Model-test page: http://127.0.0.1:8010' }
    'console-down' { docker compose --profile console stop console }
}
