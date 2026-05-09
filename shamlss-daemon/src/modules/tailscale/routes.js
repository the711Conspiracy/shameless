'use strict'
const express = require('express')
const QRCode = require('qrcode')
const router = express.Router()
const log = require('../../core/log')
const flags = require('../feature-flags')
const manager = require('./manager')

function ensureFlag(req, res) {
  if (!flags.is('p10_wireguard')) {
    res.status(403).json({ error: 'feature disabled: p10_wireguard' })
    return false
  }
  return true
}

// GET /tailscale/status
// Returns connection state, Tailscale IP, coordinator URL.
router.get('/status', async (req, res) => {
  if (!ensureFlag(req, res)) return
  try {
    res.json(await manager.status())
  } catch (e) {
    log.error('tailscale', 'status failed', e)
    res.status(500).json({ error: e.message })
  }
})

// GET /tailscale/config
// Returns persistent config (coordinator_url, hostname, state_dir).
router.get('/config', (req, res) => {
  if (!ensureFlag(req, res)) return
  res.json(manager.getConfig())
})

// PATCH /tailscale/config
// Update coordinator_url (point to Headscale) or hostname.
// coordinator_url defaults to https://controlplane.tailscale.com; swap for self-hosted Headscale.
router.patch('/config', (req, res) => {
  if (!ensureFlag(req, res)) return
  const { coordinator_url, hostname } = req.body || {}
  const patch = {}
  if (coordinator_url !== undefined) patch.coordinator_url = coordinator_url
  if (hostname !== undefined) patch.hostname = hostname
  res.json(manager.saveConfig(patch))
})

// GET /tailscale/auth
// Start the interactive auth flow. Returns:
//   { auth_url, qr }          — when login is needed (scan QR with Tailscale app or browser)
//   { status: 'already_authenticated', tailscale_ip }  — when already connected
//
// After the user authenticates, poll GET /tailscale/status until state === 'Running'.
router.get('/auth', async (req, res) => {
  if (!ensureFlag(req, res)) return
  try {
    if (!(await manager.isInstalled())) {
      return res.status(503).json({
        error: 'tailscale not installed',
        install_url: 'https://tailscale.com/download',
      })
    }
    log.info('tailscale', 'auth flow requested')
    const authUrl = await manager.startAuth()

    if (!authUrl) {
      const st = await manager.status()
      log.info('tailscale', `already authenticated — IP: ${st.tailscale_ip}`)
      return res.json({ status: 'already_authenticated', tailscale_ip: st.tailscale_ip })
    }

    // PNG data URL — 256px, minimal margin, works inline in HTML <img> or Web UI
    const qr = await QRCode.toDataURL(authUrl, { width: 256, margin: 1 })
    log.info('tailscale', `auth URL ready: ${authUrl}`)
    res.json({ auth_url: authUrl, qr })
  } catch (e) {
    log.error('tailscale', 'auth failed', e)
    res.status(500).json({ error: e.message })
  }
})

// POST /tailscale/up
// Body (optional): { auth_key, login_server }
// Use auth_key for headless / unattended pairing (generate a pre-auth key in the Tailscale admin panel).
router.post('/up', async (req, res) => {
  if (!ensureFlag(req, res)) return
  try {
    if (!(await manager.isInstalled())) {
      return res.status(503).json({ error: 'tailscale not installed', install_url: 'https://tailscale.com/download' })
    }
    const { auth_key, login_server } = req.body || {}
    await manager.connect({ auth_key, login_server })
    const st = await manager.status()
    log.info('tailscale', `connected — IP: ${st.tailscale_ip}`)
    res.json(st)
  } catch (e) {
    log.error('tailscale', 'up failed', e)
    res.status(500).json({ error: e.message })
  }
})

// POST /tailscale/down
// Disconnect from the tailnet.
router.post('/down', async (req, res) => {
  if (!ensureFlag(req, res)) return
  try {
    await manager.disconnect()
    log.info('tailscale', 'disconnected')
    res.json({ ok: true })
  } catch (e) {
    log.error('tailscale', 'down failed', e)
    res.status(500).json({ error: e.message })
  }
})

module.exports = router
