# Download the frozen face model from InsightFace's official release (Windows).
# The weights are non-commercial research only and are NOT redistributed with
# this project; this fetches them from the original source and verifies the hash.
$ErrorActionPreference = "Stop"
$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$Dest = Join-Path $Root ".local\spike\models\buffalo_sc"
$Url = "https://github.com/deepinsight/insightface/releases/download/v0.7/buffalo_sc.zip"
$ZipSha = "57d31b56b6ffa911c8a73cfc1707c73cab76efe7f13b675a05223bf42de47c72"

New-Item -ItemType Directory -Force $Dest | Out-Null
if ((Test-Path (Join-Path $Dest "det_500m.onnx")) -and (Test-Path (Join-Path $Dest "w600k_mbf.onnx"))) {
    Write-Host "Model already present in $Dest - nothing to do."
    exit 0
}

$Tmp = Join-Path $Dest "buffalo_sc.zip"
Write-Host "Downloading model (non-commercial research use) from InsightFace..."
Invoke-WebRequest -Uri $Url -OutFile $Tmp

$Actual = (Get-FileHash $Tmp -Algorithm SHA256).Hash.ToLower()
if ($Actual -ne $ZipSha) {
    Remove-Item $Tmp -Force
    throw "Checksum mismatch (got $Actual). Download may be corrupt; not extracting."
}

Expand-Archive -Path $Tmp -DestinationPath $Dest -Force
Write-Host "Model ready in $Dest (det_500m.onnx + w600k_mbf.onnx)."
Write-Host "Licensed for non-commercial academic research only; do not redistribute."
