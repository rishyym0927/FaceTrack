$ErrorActionPreference = "Stop"
$Root = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
Set-Location $Root
docker compose -f compose.windows.yaml down
Write-Host "Backend containers stopped. Close the Student and Teacher Flutter windows if they are open."
