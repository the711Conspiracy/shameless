#!/usr/bin/env bash
# Shamlss Server Installer — macOS
# Usage: bash install-server-macos.sh [--install-dir /path] [--no-agent] [--uninstall]
set -euo pipefail

INSTALL_DIR="${SHAMLSS_INSTALL_DIR:-$HOME/Library/Application Support/shamlss-server}"
NO_AGENT=false
UNINSTALL=false
LOG_FILE="$TMPDIR/shamlss-install.log"
PLIST="$HOME/Library/LaunchAgents/com.shamlss.server.plist"

log() { local ts; ts=$(date '+%Y-%m-%d %H:%M:%S'); echo "[$ts] $*" | tee -a "$LOG_FILE"; }
die() { log "ERROR: $*"; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-dir) INSTALL_DIR="$2"; shift 2 ;;
    --no-agent)    NO_AGENT=true; shift ;;
    --uninstall)   UNINSTALL=true; shift ;;
    *) die "Unknown argument: $1" ;;
  esac
done

uninstall() {
  log "=== Shamlss Server Uninstall ==="
  launchctl unload "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  rm -rf "$INSTALL_DIR"
  log "Uninstall complete"
  exit 0
}
$UNINSTALL && uninstall

check_node() {
  if command -v node &>/dev/null; then
    log "Node.js $(node --version) found at $(command -v node)"
    return 0
  fi
  log "Node.js not found — installing..."

  if command -v brew &>/dev/null; then
    log "Using Homebrew to install Node.js..."
    brew install node@22 >> "$LOG_FILE" 2>&1
    brew link --force node@22 >> "$LOG_FILE" 2>&1 || true
  else
    log "Homebrew not found — installing nvm then Node.js..."
    export NVM_DIR="$HOME/.nvm"
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.0/install.sh | bash >> "$LOG_FILE" 2>&1
    [ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"
    nvm install 22 >> "$LOG_FILE" 2>&1
    nvm use 22 >> "$LOG_FILE" 2>&1
    nvm alias default 22 >> "$LOG_FILE" 2>&1
  fi
  command -v node &>/dev/null || die "Node.js install failed"
  log "Node.js $(node --version) installed"
}

install_daemon() {
  log "Installing Shamlss daemon to: $INSTALL_DIR"
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  SRC="$SCRIPT_DIR/../shamlss-daemon"
  [ -d "$SRC" ] || SRC="$(dirname "$SCRIPT_DIR")/shamlss-daemon"
  [ -d "$SRC" ] || die "shamlss-daemon source not found"

  mkdir -p "$INSTALL_DIR"
  rsync -a --exclude='node_modules' --exclude='.cache' "$SRC/" "$INSTALL_DIR/"
  cd "$INSTALL_DIR"
  log "Installing npm dependencies..."
  npm install --omit=dev >> "$LOG_FILE" 2>&1
  log "Dependencies installed"
}

install_launch_agent() {
  $NO_AGENT && return
  NODE_BIN=$(command -v node)
  LOG_DIR="$HOME/.shamlss"
  mkdir -p "$LOG_DIR"
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$PLIST" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.shamlss.server</string>
  <key>ProgramArguments</key>
  <array>
    <string>$NODE_BIN</string>
    <string>$INSTALL_DIR/src/daemon.js</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict><key>SuccessfulExit</key><false/></dict>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/daemon.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/daemon.log</string>
</dict>
</plist>
EOF
  launchctl load "$PLIST"
  log "LaunchAgent installed and loaded: $PLIST"
}

log "=== Shamlss Server Install ==="
log "Log: $LOG_FILE"
log "Install dir: $INSTALL_DIR"
check_node
install_daemon
install_launch_agent

log "Starting daemon..."
if $NO_AGENT; then
  node "$INSTALL_DIR/src/daemon.js" &
fi
sleep 3

if curl -sf http://127.0.0.1:7432/ping > /tmp/shamlss-ping.json 2>/dev/null; then
  log "Daemon running"
  log ""
  log "=== Install complete ==="
  log "Web player: http://localhost:7432/ui"
  log "Daemon log: $HOME/.shamlss/daemon.log"
  echo ""
  echo "Shamlss is running at http://localhost:7432/ui"
else
  log "WARNING: daemon did not respond — check $HOME/.shamlss/daemon.log"
fi
