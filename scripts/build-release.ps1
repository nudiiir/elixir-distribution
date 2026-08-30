# Builds server + client and compiles both Inno Setup installers into dist\.
# Usage: powershell -ExecutionPolicy Bypass -File scripts\build-release.ps1
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

$env:PATH = "C:\Program Files\Go\bin;$env:PATH"
$flutter = "D:\flutter\bin\flutter.bat"
$isccCandidates = @(
  "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
  "C:\Program Files (x86)\Inno Setup 6\ISCC.exe",
  "C:\Program Files\Inno Setup 6\ISCC.exe"
)
$iscc = $isccCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) { throw "Inno Setup (ISCC.exe) introuvable" }

Write-Output "=== 1/4 Go server ==="
Set-Location "$root\server"
go build -ldflags "-s -w" -o server.exe ./cmd/server
if (-not $?) { throw "server build failed" }

Write-Output "=== 2/4 Flutter client (release) ==="
Set-Location "$root\app"
& $flutter build windows --release
if (-not $?) { throw "flutter build failed" }

New-Item -ItemType Directory -Force "$root\dist" | Out-Null

Write-Output "=== 3/4 Installateur serveur ==="
& $iscc "$root\installer\server.iss"
if (-not $?) { throw "server installer failed" }

Write-Output "=== 4/4 Installateur client ==="
& $iscc "$root\installer\client.iss"
if (-not $?) { throw "client installer failed" }

Write-Output ""
Write-Output "=== OK — installateurs dans dist\ ==="
Get-ChildItem "$root\dist" | Select-Object Name, @{n='Mo';e={[math]::Round($_.Length/1MB,1)}}
