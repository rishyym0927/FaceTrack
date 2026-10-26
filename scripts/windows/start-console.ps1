[CmdletBinding()]
param([switch]$NoBuild)

$ErrorActionPreference = "Stop"
$Root = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
Set-Location $Root

$Required = @(
    ".local/spike/models/buffalo_sc/manifest.json",
    ".local/spike/profiles/frozen-phase1b-v1.json",
    ".local/console-web/index.html"
)
foreach ($Relative in $Required) {
    if (-not (Test-Path (Join-Path $Root $Relative))) {
        throw "Missing file: $Relative. Follow docs/MODEL_TEST_CONSOLE.md (private files must be copied first)."
    }
}
& docker info *> $null
if ($LASTEXITCODE -ne 0) { throw "Docker Desktop is not running. Start it, wait until it says Running, then try again." }

$ComposeArgs = @("compose", "-f", "compose.windows.yaml", "--profile", "console", "up", "-d")
if (-not $NoBuild) { $ComposeArgs += "--build" }
$ComposeArgs += "console"
& docker @ComposeArgs
if ($LASTEXITCODE -ne 0) { throw "The test service did not start. Run: docker compose -f compose.windows.yaml logs console" }

$Ready = $false
for ($Attempt = 0; $Attempt -lt 30; $Attempt++) {
    try {
        $Status = Invoke-RestMethod "http://127.0.0.1:8010/api/status" -TimeoutSec 3
        $Ready = $true
        break
    } catch { Start-Sleep -Seconds 2 }
}
if (-not $Ready) { throw "The test service is not answering. Run: docker compose -f compose.windows.yaml logs console" }
if (-not $Status.integrity.ok) { Write-Host ("Warning: " + $Status.integrity.message) -ForegroundColor Yellow }
Write-Host "Model test page is ready: http://127.0.0.1:8010" -ForegroundColor Green
Start-Process "http://127.0.0.1:8010"
