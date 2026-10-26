$ErrorActionPreference = "Stop"
$Root = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
Set-Location $Root
docker compose -f compose.windows.yaml --profile console stop console
Write-Host "Model test service stopped. Volunteer data is kept; use the page's Delete button to erase it."
