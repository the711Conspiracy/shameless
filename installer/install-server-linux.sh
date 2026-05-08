#!/usr/bin/env bash
# Shamlss Server Installer — Linux
# Supports: Ubuntu/Debian, Fedora/RHEL, Arch, Alpine
# Usage: bash install-server-linux.sh [--install-dir /path] [--no-service] [--uninstall]
set -euo pipefail

INSTALL_DIR="${SHAMLSS_INSTALL_DIR:-$HOME/.local/lib/shamlss-server}"
SERVICE_USER="${SHAMLSS_USER:-$USER}"
NO_SERVICE=false
UNINSTALL=false
LOG_FILE="/tmp/shamlss-install.log"
NODE_VERSION="22.13.0"

log() { local ts; ts=$(date '+%Y-%m-%d %H:%M:%S'); echo "[$ts] $*" | tee -a "$LOG_FILE"; }
die() { log "ERROR: $*"; exit 1; }

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-dir) INSTALL_DIR="$2"; shift 2 ;;
    --no-service)  NO_SERVICE=true; shift ;;
    --uninstall)   UNINSTALL=true; shift ;;
    *) die "Unknown argument: $1" ;;
  esac
done

uninstall() {
  log "=== Shamlss Server Uninstall ==="
  systemctl --user stop shamlss-server 2>/dev/null || true
  systemctl --user disable shamlss-server 2>/dev/null || true
  rm -f "$HOME/.config/systemd/user/shamlss-server.service"
  systemctl --user daemon-reload 2>/dev/null || true
  rm -rf "$INSTALL_DIR"
  log "Uninstall complete"
  exit 0
}

$UNINSTALL && uninstall

check_node() {
  if command -v node &>/dev/null; then
    local ver; ver=$(node --version | tr -d 'v')
    log "Node.js $ver found at $(command -v node)"
    return 0
  fi
  log "Node.js not found — installing..."
  install_node
}

install_node() {
  # Try NodeSource first for Debian/Ubuntu/RHEL
  if command -v apt-get &>/dev/null; then
    log "Detected apt — installing Node.js via NodeSource..."
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >> "$LOG_FILE" 2>&1
    apt-get install -y nodejs >> "$LOG_FILE" 2>&1
  elif command -v dnf &>/dev/null; then
    log "Detected dnf — installing Node.js..."
    dnf module install -y nodejs:22 >> "$LOG_FILE" 2>&1
  elif command -v yum &>/dev/null; then
    log "Detected yum — installing Node.js via NodeSource..."
    curl -fsSL https://rpm.nodesource.com/setup_22.x | bash - >> "$LOG_FILE" 2>&1
    yum install -y nodejs >> "$LOG_FILE" 2>&1
  elif command -v pacman &>/dev/null; then
    log "Detected pacman — installing Node.js..."
    pacman -S --noconfirm nodejs npm >> "$LOG_FILE" 2>&1
  elif command -v apk &>/dev/null; then
    log "Detected apk — installing Node.js..."
    apk add --no-cache nodejs npm >> "$LOG_FILE" 2>&1
  else
    log "No supported package manager found — installing via nvm..."
    export NVM_DIR="$HOME/.nvm"
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.0/install.sh | bash >> "$LOG_FILE" 2>&1
    # shellcheck source=/dev/null
    [ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"
    nvm install "$NODE_VERSION" >> "$LOG_FILE" 2>&1
    nvm use "$NODE_VERSION" >> "$LOG_FILE" 2>&1
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
  rsync -a --exclude='node_modules' --exclude='.cache' "$SRC/" "$INSTALL_DIR/" 2>/dev/null \
    || cp -r "$SRC/." "$INSTALL_DIR/"
  cd "$INSTALL_DIR"
  log "Installing npm dependencies..."
  npm install --omit=dev >> "$LOG_FILE" 2>&1
  log "Dependencies installed"
}

install_service() {
  $NO_SERVICE && return
  SYSTEMD_DIR="$HOME/.config/systemd/user"
  mkdir -p "$SYSTEMD_DIR"
  NODE_BIN=$(command -v node)
  cat > "$SYSTEMD_DIR/shamlss-server.service" << EOF
[Unit]
Description=Shamlss Music Server
After=network.target

[Service]
Type=simple
ExecStart=$NODE_BIN $INSTALL_DIR/src/daemon.js
Restart=on-failure
RestartSec=5
StandardOutput=append:%h/.shamlss/daemon.log
StandardError=append:%h/.shamlss/daemon.log

[Install]
WantedBy=default.target
EOF

  systemctl --user daemon-reload
  systemctl --user enable shamlss-server
  log "systemd user service installed and enabled"
}

log "=== Shamlss Server Install ==="
log "Log: $LOG_FILE"
log "Install dir: $INSTALL_DIR"
check_node
install_daemon
install_service

log "Starting daemon..."
if $NO_SERVICE; then
  node "$INSTALL_DIR/src/daemon.js" &
  DAEMON_PID=$!
  sleep 3
else
  systemctl --user start shamlss-server
  sleep 3
fi

if curl -sf http://127.0.0.1:7432/ping > /tmp/shamlss-ping.json 2>/dev/null; then
  NODE_ID=$(python3 -c "import json,sys; d=json.load(open('/tmp/shamlss-ping.json')); print(d['node_id'])" 2>/dev/null || echo "unknown")
  log "Daemon running — node_id: $NODE_ID"
  log ""
  log "=== Install complete ==="
  log "Web player: http://localhost:7432/ui"
  log "Daemon log: $HOME/.shamlss/daemon.log"
  echo ""
  echo "Shamlss is running at http://localhost:7432/ui"
else
  log "WARNING: daemon did not respond — check $HOME/.shamlss/daemon.log"
fi
