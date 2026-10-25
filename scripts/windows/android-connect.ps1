$ErrorActionPreference = "Stop"
$Adb = Get-Command adb -ErrorAction SilentlyContinue
if ($Adb) {
    $AdbPath = $Adb.Source
} else {
    $AdbPath = Join-Path $env:LOCALAPPDATA "Android/Sdk/platform-tools/adb.exe"
}
if (-not (Test-Path $AdbPath)) {
    throw "adb was not found. Install Android SDK Platform-Tools or add adb to PATH."
}
& $AdbPath get-state
if ($LASTEXITCODE -ne 0) { throw "No authorized Android phone found. Unlock it and accept USB debugging." }
& $AdbPath reverse tcp:8000 tcp:8000
& $AdbPath reverse --list
Write-Host "Android can now reach the local API at 127.0.0.1:8000." -ForegroundColor Green
