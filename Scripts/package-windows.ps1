# Build SendHere for Windows x64 and package it as a timestamped ZIP in dist/.
# Run on Windows from the repo root:  powershell -ExecutionPolicy Bypass -File Scripts\package-windows.ps1
# Requires: Flutter stable + Visual Studio 2022 with "Desktop development with C++".
$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$AppName = "SendHere"
$Dist = Join-Path $Root "dist"
$VersionLine = (Select-String -Path (Join-Path $Root "pubspec.yaml") -Pattern '^version:').Line
$Full = ($VersionLine -split '\s+')[1]
$Version = ($Full -split '\+')[0]
$Build = ($Full -split '\+')[1]
$Stamp = Get-Date -Format "yyyyMMdd-HHmm"
$ZipPath = Join-Path $Dist "$AppName-$Version-build$Build-$Stamp-win-x64.zip"

Set-Location $Root
Write-Host "-> flutter pub get"
flutter pub get
if ($LASTEXITCODE -ne 0) { throw "flutter pub get failed" }

Write-Host "-> Building Windows release..."
flutter build windows --release
if ($LASTEXITCODE -ne 0) { throw "flutter build windows failed" }

$ReleaseDir = Join-Path $Root "build\windows\x64\runner\Release"
New-Item -ItemType Directory -Force -Path $Dist | Out-Null
if (Test-Path $ZipPath) { Remove-Item $ZipPath }
Compress-Archive -Path (Join-Path $ReleaseDir "*") -DestinationPath $ZipPath

$Hash = (Get-FileHash -Algorithm SHA256 $ZipPath).Hash.ToLower()
"$Hash  $(Split-Path -Leaf $ZipPath)" | Out-File -Encoding ascii "$ZipPath.sha256"
Write-Host "OK ZIP ready: $ZipPath"
Write-Host "Unzip anywhere and run send_here.exe. Allow it through Windows Firewall on first launch."
