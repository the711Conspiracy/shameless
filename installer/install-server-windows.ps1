#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Shamlss Server Installer for Windows
.DESCRIPTION
    Installs Node.js (if needed), copies the Shamlss daemon, installs npm
    dependencies, creates a Windows startup entry, and launches the server.
    All steps are logged to %TEMP%\shamlss-install.log.
#>
param(
    [string]$InstallDir = "$env:APPDATA\shamlss-server",
    [switch]$NoStartup,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$LOG = "$env:TEMP\shamlss-install.log"
$NODE_VERSION = "22.13.0"
$NODE_URL = "https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-x64.msi"

function Log([string]$msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] $msg"
    Write-Host $line
    Add-Content -Path $LOG -Value $line -Encoding UTF8
}

function Assert-Node {
    $node = Get-Command node -ErrorAction SilentlyContinue
    if ($node) {
        $ver = (node --version 2>&1).TrimStart('v')
        Log "Node.js $ver found at $($node.Source)"
        return
    }
    Log "Node.js not found — downloading v$NODE_VERSION installer..."
    $msi = "$env:TEMP\node-installer.msi"
    Invoke-WebRequest -Uri $NODE_URL -OutFile $msi -UseBasicParsing
    Log "Installing Node.js (this may take a minute)..."
    Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /quiet /norestart" -Wait
    Remove-Item $msi -Force
    # Refresh PATH
    $env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path','User')
    $ver = (node --version 2>&1).TrimStart('v')
    Log "Node.js $ver installed"
}

function Install-Daemon {
    Log "Installing Shamlss daemon to: $InstallDir"
    $src = Join-Path $PSScriptRoot "..\shamlss-daemon"
    if (-not (Test-Path $src)) {
        $src = Join-Path (Split-Path $PSScriptRoot) "shamlss-daemon"
    }
    if (-not (Test-Path $src)) {
        Log "ERROR: shamlss-daemon source not found relative to installer"
        exit 1
    }
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    Log "Copying daemon files..."
    Copy-Item -Path "$src\*" -Destination $InstallDir -Recurse -Force -Exclude "node_modules"
    Set-Location $InstallDir
    Log "Installing npm dependencies..."
    $npmOut = npm install --omit=dev 2>&1
    $npmOut | ForEach-Object { Log "  npm: $_" }
    Log "Dependencies installed"
}

function Set-Startup {
    if ($NoStartup) { return }
    $startupDir = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
    $vbs = "$startupDir\shamlss-server.vbs"
    Log "Creating startup entry: $vbs"
    @"
Set WshShell = CreateObject("WScript.Shell")
WshShell.Run "cmd /c node `"$InstallDir\src\daemon.js`" >> `"%APPDATA%\.shamlss\daemon.log`" 2>&1", 0, False
"@ | Set-Content $vbs -Encoding UTF8
    Log "Startup entry created — daemon will launch on next login"
}

function Remove-Startup {
    $vbs = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\shamlss-server.vbs"
    if (Test-Path $vbs) { Remove-Item $vbs -Force; Log "Removed startup entry" }
}

if ($Uninstall) {
    Log "=== Shamlss Server Uninstall ==="
    Remove-Startup
    # Kill any running daemon
    Get-Process -Name node -ErrorAction SilentlyContinue | Where-Object {
        $_.MainModule.FileName -like "*$InstallDir*"
    } | Stop-Process -Force -ErrorAction SilentlyContinue
    if (Test-Path $InstallDir) {
        Remove-Item $InstallDir -Recurse -Force
        Log "Removed $InstallDir"
    }
    Log "Uninstall complete"
    exit 0
}

Log "=== Shamlss Server Install ==="
Log "Log: $LOG"
Log "Install dir: $InstallDir"
Assert-Node
Install-Daemon
Set-Startup

# Launch now
Log "Launching Shamlss daemon..."
$nodeExe = (Get-Command node).Source
Start-Process $nodeExe -ArgumentList "`"$InstallDir\src\daemon.js`"" -WindowStyle Hidden
Start-Sleep 3

try {
    $ping = Invoke-RestMethod -Uri "http://127.0.0.1:7432/ping" -TimeoutSec 5
    Log "Daemon running — node_id: $($ping.node_id), name: $($ping.name)"
    Log ""
    Log "=== Install complete ==="
    Log "Web player: http://localhost:7432/ui"
    Log "Daemon log: $env:APPDATA\.shamlss\daemon.log"
    Write-Host ""
    Write-Host "Shamlss is running at http://localhost:7432/ui" -ForegroundColor Green
} catch {
    Log "WARNING: daemon did not respond after launch — check $env:APPDATA\.shamlss\daemon.log"
}
