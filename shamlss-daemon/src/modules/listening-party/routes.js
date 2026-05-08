'use strict'
const express = require('express')
const router = express.Router()
const crypto = require('crypto')
const db = require('../../core/db')
const log = require('../../core/log')
const events = require('../events')
const flags = require('../feature-flags')

function ensureFlag(req, res) {
  if (!flags.is('p8_listening_party')) {
    res.status(403).json({ error: 'feature disabled: p8_listening_party' })
    return false
  }
  return true
}

function getLocalNodeId() {
  const row = db.prepare('SELECT node_id FROM nodes LIMIT 1').get()
  return row?.node_id || null
}

// POST /party/create — create a party with this node as host
router.post('/create', (req, res) => {
  if (!ensureFlag(req, res)) return
  try {
    const hostNodeId = req.body?.host_node_id || getLocalNodeId()
    if (!hostNodeId) return res.status(500).json({ error: 'no node identity' })
    const id = crypto.randomUUID()
    db.prepare(`
      INSERT INTO listening_party (id, host_node_id, track_id, position_ms, playing, updated_ts)
      VALUES (?, ?, NULL, 0, 0, ?)
    `).run(id, hostNodeId, Date.now())
    log.info('party', `created ${id} host=${hostNodeId}`)
    events.emit('party.created', { party_id: id, host_node_id: hostNodeId })
    res.status(201).json({ party_id: id, host_node_id: hostNodeId })
  } catch (e) {
    log.error('party', 'create failed', e)
    res.status(500).json({ error: 'create failed' })
  }
})

// GET /party/:id — current party state
router.get('/:id', (req, res) => {
  if (!ensureFlag(req, res)) return
  try {
    const row = db.prepare('SELECT * FROM listening_party WHERE id = ?').get(req.params.id)
    if (!row) return res.status(404).json({ error: 'not found' })
    res.json({
      party_id: row.id,
      host_node_id: row.host_node_id,
      track_id: row.track_id,
      position_ms: row.position_ms,
      playing: !!row.playing,
      updated_ts: row.updated_ts
    })
  } catch (e) {
    log.error('party', 'get failed', e)
    res.status(500).json({ error: 'get failed' })
  }
})

// POST /party/:id/state — host updates state, broadcasts party.state
router.post('/:id/state', (req, res) => {
  if (!ensureFlag(req, res)) return
  try {
    const party = db.prepare('SELECT * FROM listening_party WHERE id = ?').get(req.params.id)
    if (!party) return res.status(404).json({ error: 'not found' })

    const callerNodeId = req.body?.host_node_id || req.podContext?.node_id || getLocalNodeId()
    if (callerNodeId !== party.host_node_id) {
      log.warn('party', `state update rejected: ${callerNodeId} is not host of ${req.params.id}`)
      return res.status(403).json({ error: 'only host can update state' })
    }

    const { track_id, position_ms, playing } = req.body || {}
    const trackId = track_id !== undefined ? track_id : party.track_id
    const pos = position_ms !== undefined ? Math.max(0, parseInt(position_ms, 10) || 0) : party.position_ms
    const isPlaying = playing !== undefined ? (playing ? 1 : 0) : party.playing
    const ts = Date.now()

    db.prepare(`
      UPDATE listening_party
      SET track_id = ?, position_ms = ?, playing = ?, updated_ts = ?
      WHERE id = ?
    `).run(trackId, pos, isPlaying, ts, req.params.id)

    const payload = {
      party_id: req.params.id,
      host_node_id: party.host_node_id,
      track_id: trackId,
      position_ms: pos,
      playing: !!isPlaying,
      updated_ts: ts
    }
    events.emit('party.state', payload)
    log.debug('party', `state ${req.params.id} track=${trackId} pos=${pos} playing=${!!isPlaying}`)
    res.json(payload)
  } catch (e) {
    log.error('party', 'state update failed', e)
    res.status(500).json({ error: 'state update failed' })
  }
})

// DELETE /party/:id — host closes the party
router.delete('/:id', (req, res) => {
  if (!ensureFlag(req, res)) return
  try {
    const party = db.prepare('SELECT host_node_id FROM listening_party WHERE id = ?').get(req.params.id)
    if (!party) return res.status(404).json({ error: 'not found' })

    const callerNodeId = req.body?.host_node_id || req.podContext?.node_id || getLocalNodeId()
    if (callerNodeId !== party.host_node_id) {
      return res.status(403).json({ error: 'only host can close party' })
    }

    db.prepare('DELETE FROM listening_party WHERE id = ?').run(req.params.id)
    log.info('party', `closed ${req.params.id}`)
    events.emit('party.closed', { party_id: req.params.id })
    res.json({ ok: true })
  } catch (e) {
    log.error('party', 'close failed', e)
    res.status(500).json({ error: 'close failed' })
  }
})

module.exports = router
