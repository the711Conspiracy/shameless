#Requires -Version 5
<#
.SYNOPSIS
    Build Shamlss Flutter app for all available platforms.
.DESCRIPTION
    Runs flutter build for each platform supported on this machine.
    Artifacts land in shamlss_flutter/build/.
    All output is logged to build-flutter.log.
#>
param(
    [string[]]$Platforms = @('apk', 'windows'),
    [switch]$Release,
    [switch]$All
)

$ROOT = Split-Path $PSScriptRoot
$FLUTTER_DIR = Join-Path $ROOT "shamlss_flutter"
$LOG = Join-Path $ROOT "build-flutter.log"
$BUILD_MODE = if ($Release) { "--release" } else { "--debug" }

function Log([string]$msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] $msg"
    Write-Host $line
    Add-Content -Path $LOG -Value $line -Encoding UTF8
}

function Invoke-FlutterBuild([string]$platform) {
    Log "=== Building $platform $BUILD_MODE ==="
    Set-Location $FLUTTER_DIR
    $result = flutter build $platform $BUILD_MODE 2>&1
    $result | ForEach-Object { Add-Content -Path $LOG -Value $_ -Encoding UTF8 }
    if ($LASTEXITCODE -ne 0) {
        Log "FAILED: flutter build $platform (exit $LASTEXITCODE)"
        return $false
    }
    Log "OK: $platform build succeeded"
    return $true
}

function Get-ArtifactPath([string]$platform) {
    switch ($platform) {
        'apk'     { return "$FLUTTER_DIR\build\app\outputs\flutter-apk\app-debug.apk" }
        'appbundle' { return "$FLUTTER_DIR\build\app\outputs\bundle\release\app-release.aab" }
        'windows' { return "$FLUTTER_DIR\build\windows\x64\runner\Debug" }
        'linux'   { return "$FLUTTER_DIR\build\linux\x64\debug\bundle" }
        'macos'   { return "$FLUTTER_DIR\build\macos\Build\Products\Debug" }
        default   { return "unknown" }
    }
}

Log "=== Shamlss Flutter Build ==="
Log "Root: $ROOT"
Log "Log: $LOG"

# flutter pub get first
Set-Location $FLUTTER_DIR
Log "Running flutter pub get..."
flutter pub get 2>&1 | ForEach-Object { Add-Content -Path $LOG -Value $_ -Encoding UTF8 }

if ($All) {
    $Platforms = @('apk', 'windows')
    # Check if on macOS for ios/macos targets
    if ($env:OS -notmatch 'Windows') {
        $Platforms += @('ios', 'macos', 'linux')
    }
}

$results = @{}
foreach ($p in $Platforms) {
    $ok = Invoke-FlutterBuild $p
    $results[$p] = $ok
    if ($ok) {
        $artifact = Get-ArtifactPath $p
        Log "  Artifact: $artifact"
    }
}

Log ""
Log "=== Build Summary ==="
foreach ($p in $results.Keys) {
    $status = if ($results[$p]) { "OK" } else { "FAILED" }
    Log "  $p : $status"
}
