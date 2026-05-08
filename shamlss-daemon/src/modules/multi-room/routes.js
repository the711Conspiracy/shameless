'use strict'
const express = require('express')
const router = express.Router()
const http = require('http')
const net = require('net')
const db = require('../../core/db')
const log = require('../../core/log')
const flags = require('../feature-flags')

const PEER_REQUEST_TIMEOUT_MS = 5000
const MAX_RESPONSE_BYTES = 64 * 1024

// In-memory map of peer_node_id -> { party_id, peer_ip, peer_port }
const _activeCasts = new Map()

function ensureFlag(req, res) {
  if (!flags.is('p10_multi_room')) {
    res.status(403).json({ error: 'feature disabled: p10_multi_room' })
    return false
  }
  return true
}

function isPrivateIp(ip) {
  // Allow LAN-only targets; reject loopback/cloud/public IPs to prevent SSRF.
  if (!ip || typeof ip !== 'string') return false
  if (!net.isIPv4(ip)) return false
  const parts = ip.split('.').map(n => parseInt(n, 10))
  if (parts.some(p => isNaN(p) || p < 0 || p > 255)) return false
  const [a, b] = parts
  if (a === 10) return true
  if (a === 172 && b >= 16 && b <= 31) return true
  if (a === 192 && b === 168) return true
  if (a === 169 && b === 254) return true // link-local
  return false
}

function peerRequest({ ip, port, method, path, body }) {
  return new Promise((resolve, reject) => {
    if (!isPrivateIp(ip)) return reject(new Error(`peer ip ${ip} is not on private LAN`))
    const portNum = parseInt(port, 10)
    if (!Number.isInteger(portNum) || portNum <= 0 || portNum > 65535) {
      return reject(new Error('invalid peer port'))
    }
    const data = body ? Buffer.from(JSON.stringify(body), 'utf8') : null
    const req = http.request({
      host: ip,
      port: portNum,
      method,
      path,
      headers: {
        'Content-Type': 'application/json',
        ...(data ? { 'Content-Length': data.length } : {})
      },
      timeout: PEER_REQUEST_TIMEOUT_MS
    }, (res) => {
      const chunks = []
      let total = 0
      let aborted = false
      res.on('data', (chunk) => {
        if (aborted) return
        total += chunk.length
        if (total > MAX_RESPONSE_BYTES) {
          aborted = true
          res.destroy()
          return reject(new Error('response too large'))
        }
        chunks.push(chunk)
      })
      res.on('end', () => {
        if (aborted) return
        const text = Buffer.concat(chunks).toString('utf8')
        let parsed = null
        try { parsed = text ? JSON.parse(text) : null } catch { parsed = { raw: text } }
        resolve({ status: res.statusCode, body: parsed })
      })
      res.on('error', reject)
    })
    req.on('timeout', () => { req.destroy(new Error('peer request timed out')) })
    req.on('error', reject)
    if (data) req.write(data)
    req.end()
  })
}

function getPeer(peerNodeId) {
  return db.prepare('SELECT node_id, last_ip, last_port, last_seen_ts FROM peers WHERE node_id = ?').get(peerNodeId)
}

// GET /multiroom/rooms — list known peers eligible for casting
router.get('/rooms', (req, res) => {
  if (!ensureFlag(req, res)) return
  try {
    const since = Date.now() - 60000
    const rows = db.prepare(`
      SELECT node_id, last_ip, last_port, last_seen_ts,
             (last_seen_ts > ?) AS online
      FROM peers
      WHERE last_ip IS NOT NULL
      ORDER BY last_seen_ts DESC
    `).all(since)
    const enriched = rows.map(r => ({
      ...r,
      online: !!r.online,
      castable: !!r.last_ip && isPrivateIp(r.last_ip),
      active_cast: _activeCasts.has(r.node_id) ? _activeCasts.get(r.node_id).party_id : null
    }))
    res.json(enriched)
  } catch (e) {
    log.error('multi-room', 'rooms list failed', e)
    res.status(500).json({ error: 'rooms list failed' })
  }
})

// POST /multiroom/cast — cast playback to a peer
router.post('/cast', async (req, res) => {
  if (!ensureFlag(req, res)) return
  try {
    const { peer_node_id, track_id, position_ms, playing } = req.body || {}
    if (typeof peer_node_id !== 'string' || !peer_node_id) {
      return res.status(400).json({ error: 'peer_node_id required' })
    }
    if (typeof track_id !== 'string' || !track_id) {
      return res.status(400).json({ error: 'track_id required' })
    }

    const peer = getPeer(peer_node_id)
    if (!peer) return res.status(404).json({ error: 'peer not found' })
    if (!peer.last_ip || !isPrivateIp(peer.last_ip)) {
      return res.status(400).json({ error: 'peer has no LAN address' })
    }
    const peerPort = peer.last_port || 7432

    const localNode = db.prepare('SELECT node_id FROM nodes LIMIT 1').get()

    // Reuse active cast if present, otherwise create a party on the peer
    let partyId = _activeCasts.get(peer_node_id)?.party_id || null
    if (!partyId) {
      const createRes = await peerRequest({
        ip: peer.last_ip,
        port: peerPort,
        method: 'POST',
        path: '/party/create',
        body: { host_node_id: localNode?.node_id || null }
      })
      if (createRes.status < 200 || createRes.status >= 300 || !createRes.body?.party_id) {
        log.warn('multi-room', `peer ${peer_node_id} party create failed: ${createRes.status}`)
        return res.status(502).json({ error: 'peer rejected party create', peer_status: createRes.status })
      }
      partyId = createRes.body.party_id
      _activeCasts.set(peer_node_id, { party_id: partyId, peer_ip: peer.last_ip, peer_port: peerPort })
      log.info('multi-room', `cast started peer=${peer_node_id} party=${partyId}`)
    }

    const stateRes = await peerRequest({
      ip: peer.last_ip,
      port: peerPort,
      method: 'POST',
      path: `/party/${encodeURIComponent(partyId)}/state`,
      body: {
        host_node_id: localNode?.node_id || null,
        track_id,
        position_ms: typeof position_ms === 'number' ? position_ms : 0,
        playing: !!playing
      }
    })
    if (stateRes.status < 200 || stateRes.status >= 300) {
      log.warn('multi-room', `peer ${peer_node_id} state update failed: ${stateRes.status}`)
      return res.status(502).json({ error: 'peer rejected state update', peer_status: stateRes.status })
    }

    res.json({ ok: true, peer_node_id, party_id: partyId, peer_state: stateRes.body })
  } catch (e) {
    log.error('multi-room', 'cast failed', e)
    res.status(500).json({ error: 'cast failed', detail: e.message })
  }
})

// POST /multiroom/stop — close the cast on the peer
router.post('/stop', async (req, res) => {
  if (!ensureFlag(req, res)) return
  try {
    const { peer_node_id } = req.body || {}
    if (typeof peer_node_id !== 'string' || !peer_node_id) {
      return res.status(400).json({ error: 'peer_node_id required' })
    }

    const active = _activeCasts.get(peer_node_id)
    if (!active) return res.status(404).json({ error: 'no active cast for peer' })

    const localNode = db.prepare('SELECT node_id FROM nodes LIMIT 1').get()

    try {
      const delRes = await peerRequest({
        ip: active.peer_ip,
        port: active.peer_port,
        method: 'DELETE',
        path: `/party/${encodeURIComponent(active.party_id)}`,
        body: { host_node_id: localNode?.node_id || null }
      })
      if (delRes.status < 200 || delRes.status >= 300) {
        log.warn('multi-room', `peer ${peer_node_id} party delete returned ${delRes.status}`)
      } else {
        log.info('multi-room', `cast stopped peer=${peer_node_id} party=${active.party_id}`)
      }
    } catch (e) {
      log.warn('multi-room', `peer ${peer_node_id} delete request failed`, e)
    } finally {
      _activeCasts.delete(peer_node_id)
    }

    res.json({ ok: true, peer_node_id })
  } catch (e) {
    log.error('multi-room', 'stop failed', e)
    res.status(500).json({ error: 'stop failed' })
  }
})

module.exports = router
