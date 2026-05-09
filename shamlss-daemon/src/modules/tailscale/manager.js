'use strict'
const { exec } = require('child_process')
const fs = require('fs')
const path = require('path')
const os = require('os')
const log = require('../../core/log')

// Resolve the tailscale binary — check common install locations when not on PATH
const _WIN_PATHS = [
  'C:\\Program Files\\Tailscale\\tailscale.exe',
  'C:\\Program Files (x86)\\Tailscale\\tailscale.exe',
]
let _bin = null
function _resolveBin() {
  if (_bin) return _bin
  if (os.platform() !== 'win32') { _bin = 'tailscale'; return _bin }
  for (const p of _WIN_PATHS) {
    if (fs.existsSync(p)) { _bin = `"${p}"`; return _bin }
  }
  _bin = 'tailscale'  // fall back — may be in PATH after system restart
  return _bin
}

const STATE_DIR = path.join(os.homedir(), '.shamlss')
const CONFIG_FILE = path.join(STATE_DIR, 'tailscale.json')
const TSNET_DIR = path.join(STATE_DIR, 'tsnet')  // state dir for future embedded tsnet

const DEFAULT_COORDINATOR = 'https://controlplane.tailscale.com'

const DEFAULT_CONFIG = {
  coordinator_url: DEFAULT_COORDINATOR,  // swap to Headscale URL to self-host
  hostname: 'shamlss-node',
  state_dir: TSNET_DIR,  // informational — system tailscale manages its own state
}

let _config = null

function _ensureStateDir() {
  fs.mkdirSync(STATE_DIR, { recursive: true })
  fs.mkdirSync(TSNET_DIR, { recursive: true })
}

function loadConfig() {
  try {
    if (fs.existsSync(CONFIG_FILE)) {
      _config = { ...DEFAULT_CONFIG, ...JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf8')) }
    } else {
      _config = { ...DEFAULT_CONFIG }
    }
  } catch (e) {
    log.warn('tailscale', `config load error: ${e.message}`)
    _config = { ...DEFAULT_CONFIG }
  }
  return _config
}

function saveConfig(patch) {
  _config = { ...(getConfig()), ...patch }
  _ensureStateDir()
  fs.writeFileSync(CONFIG_FILE, JSON.stringify(_config, null, 2))
  return _config
}

function getConfig() {
  if (!_config) loadConfig()
  return _config
}

function _run(cmd, timeoutMs = 10000) {
  const bin = _resolveBin()
  const full = cmd.replace(/^tailscale\b/, bin)
  return new Promise((resolve, reject) => {
    exec(full, { timeout: timeoutMs }, (err, stdout, stderr) => {
      if (err) reject(new Error((stderr || err.message).trim()))
      else resolve(stdout.trim())
    })
  })
}

// Returns true if the tailscale binary is reachable
async function isInstalled() {
  try {
    await _run('tailscale version', 3000)
    return true
  } catch {
    return false
  }
}

// Returns parsed tailscale status, or null if tailscale is unavailable
async function _rawStatus() {
  const json = await _run('tailscale status --json')
  return JSON.parse(json)
}

// Public status summary
async function status() {
  if (!(await isInstalled())) {
    return { available: false, state: 'NotInstalled', error: 'tailscale binary not found on PATH' }
  }
  try {
    const s = await _rawStatus()
    const cfg = getConfig()
    return {
      available: true,
      state: s.BackendState,           // 'Running' | 'NeedsLogin' | 'Starting' | 'Stopped' | 'NoState'
      hostname: s.Self?.HostName || cfg.hostname,
      tailscale_ip: s.Self?.TailscaleIPs?.[0] || null,
      coordinator_url: cfg.coordinator_url,
      state_dir: cfg.state_dir,
    }
  } catch (e) {
    log.warn('tailscale', `status error: ${e.message}`)
    return { available: true, state: 'Unknown', error: e.message }
  }
}

// Start the auth flow.
// - Calls `tailscale up` to bring the daemon into NeedsLogin state if needed.
// - Polls `tailscale status --json` for the AuthURL that appears when login is required.
// - Returns the URL string, or null if already authenticated.
async function startAuth() {
  const cfg = getConfig()

  let s
  try {
    s = await _rawStatus()
  } catch {
    s = {}
  }

  if (s.BackendState === 'Running') return null

  // If the AuthURL is already in status (previous interrupted login), use it directly
  if (s.AuthURL) return s.AuthURL

  // Trigger the login flow — tailscale up without authkey causes state → NeedsLogin
  const upArgs = ['tailscale', 'up', '--hostname', cfg.hostname]
  if (cfg.coordinator_url !== DEFAULT_COORDINATOR) {
    upArgs.push('--login-server', cfg.coordinator_url)
  }
  // Expected to exit non-zero (NeedsLogin) — ignore the error
  await _run(upArgs.join(' '), 15000).catch(() => {})

  // Poll up to 6 seconds for the AuthURL to appear in status
  for (let i = 0; i < 12; i++) {
    await new Promise(r => setTimeout(r, 500))
    try {
      const fresh = await _rawStatus()
      if (fresh.AuthURL) return fresh.AuthURL
      if (fresh.BackendState === 'Running') return null
    } catch {}
  }

  throw new Error('timed out waiting for Tailscale auth URL — is tailscaled running?')
}

// Connect with an explicit pre-auth key (headless / unattended setup)
async function connect({ auth_key, login_server } = {}) {
  const cfg = getConfig()
  const server = login_server || cfg.coordinator_url

  const args = [`tailscale up --hostname=${cfg.hostname}`]
  if (server !== DEFAULT_COORDINATOR) args.push(`--login-server=${server}`)
  if (auth_key) args.push(`--authkey=${auth_key}`)

  return _run(args.join(' '), 20000)
}

async function disconnect() {
  return _run('tailscale down', 10000)
}

module.exports = { status, startAuth, connect, disconnect, getConfig, saveConfig, loadConfig, isInstalled }
