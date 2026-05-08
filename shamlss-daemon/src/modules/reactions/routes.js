'use strict'
const express = require('express')
const router = express.Router()
const crypto = require('crypto')
const db = require('../../core/db')
const log = require('../../core/log')
const events = require('../events')
const flags = require('../feature-flags')

const MAX_EMOJI_LEN = 16
const MAX_TRACK_ID_LEN = 256
const MAX_NODE_ID_LEN = 256

function ensureFlag(req, res) {
  if (!flags.is('p8_reactions')) {
    res.status(403).json({ error: 'feature disabled: p8_reactions' })
    return false
  }
  return true
}

// POST /reactions — add a reaction
router.post('/', (req, res) => {
  if (!ensureFlag(req, res)) return
  try {
    const { track_id, emoji, node_id } = req.body || {}
    if (typeof track_id !== 'string' || !track_id || track_id.length > MAX_TRACK_ID_LEN) {
      return res.status(400).json({ error: 'track_id required' })
    }
    if (typeof emoji !== 'string' || !emoji.trim() || emoji.length > MAX_EMOJI_LEN) {
      return res.status(400).json({ error: 'emoji required (max 16 chars)' })
    }
    if (typeof node_id !== 'string' || !node_id || node_id.length > MAX_NODE_ID_LEN) {
      return res.status(400).json({ error: 'node_id required' })
    }

    const id = crypto.randomUUID()
    const ts = Date.now()
    db.prepare(`
      INSERT INTO track_reactions (id, track_id, node_id, emoji, ts) VALUES (?, ?, ?, ?, ?)
    `).run(id, track_id, node_id, emoji.trim(), ts)

    const payload = { id, track_id, node_id, emoji: emoji.trim(), ts }
    events.emit('reaction.added', payload)
    log.debug('reactions', `${node_id} reacted ${emoji.trim()} to ${track_id}`)
    res.status(201).json(payload)
  } catch (e) {
    log.error('reactions', 'add failed', e)
    res.status(500).json({ error: 'add failed' })
  }
})

// GET /reactions/:track_id — last 50 reactions for a track
router.get('/:track_id', (req, res) => {
  if (!ensureFlag(req, res)) return
  try {
    const limit = Math.min(parseInt(req.query.limit) || 50, 200)
    const rows = db.prepare(`
      SELECT id, track_id, node_id, emoji, ts
      FROM track_reactions
      WHERE track_id = ?
      ORDER BY ts DESC
      LIMIT ?
    `).all(req.params.track_id, limit)
    res.json(rows)
  } catch (e) {
    log.error('reactions', 'list failed', e)
    res.status(500).json({ error: 'list failed' })
  }
})

module.exports = router
