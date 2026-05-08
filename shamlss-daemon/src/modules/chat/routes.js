'use strict'
const express = require('express')
const router = express.Router()
const crypto = require('crypto')
const db = require('../../core/db')
const log = require('../../core/log')
const events = require('../events')
const flags = require('../feature-flags')

const MAX_BODY_LEN = 2000
const MAX_NAME_LEN = 64
const MAX_NODE_ID_LEN = 256
const MAX_POD_ID_LEN = 256

function ensureFlag(req, res) {
  if (!flags.is('p8_chat')) {
    res.status(403).json({ error: 'feature disabled: p8_chat' })
    return false
  }
  return true
}

// POST /chat — store and broadcast a chat message
router.post('/', (req, res) => {
  if (!ensureFlag(req, res)) return
  try {
    const { pod_id, node_id, display_name, body } = req.body || {}

    if (typeof node_id !== 'string' || !node_id || node_id.length > MAX_NODE_ID_LEN) {
      return res.status(400).json({ error: 'node_id required' })
    }
    if (typeof body !== 'string' || !body.trim()) {
      return res.status(400).json({ error: 'body required' })
    }
    if (body.length > MAX_BODY_LEN) {
      return res.status(400).json({ error: `body too long (max ${MAX_BODY_LEN})` })
    }
    if (pod_id !== undefined && pod_id !== null && (typeof pod_id !== 'string' || pod_id.length > MAX_POD_ID_LEN)) {
      return res.status(400).json({ error: 'invalid pod_id' })
    }
    if (display_name !== undefined && display_name !== null &&
        (typeof display_name !== 'string' || display_name.length > MAX_NAME_LEN)) {
      return res.status(400).json({ error: 'invalid display_name' })
    }

    const id = crypto.randomUUID()
    const ts = Date.now()
    const safeBody = body.trim()
    const safeName = display_name ? display_name.trim() : null
    const safePodId = pod_id || null

    db.prepare(`
      INSERT INTO chat_messages (id, pod_id, node_id, display_name, body, ts)
      VALUES (?, ?, ?, ?, ?, ?)
    `).run(id, safePodId, node_id, safeName, safeBody, ts)

    const payload = { id, pod_id: safePodId, node_id, display_name: safeName, body: safeBody, ts }
    events.emit('chat.message', payload)
    log.debug('chat', `${node_id} -> pod=${safePodId || 'global'}: ${safeBody.slice(0, 80)}`)
    res.status(201).json(payload)
  } catch (e) {
    log.error('chat', 'post failed', e)
    res.status(500).json({ error: 'post failed' })
  }
})

// GET /chat?pod_id=X&limit=50 — recent messages
router.get('/', (req, res) => {
  if (!ensureFlag(req, res)) return
  try {
    const limit = Math.min(parseInt(req.query.limit) || 50, 200)
    const podId = req.query.pod_id
    let rows
    if (podId !== undefined && podId !== '') {
      if (typeof podId !== 'string' || podId.length > MAX_POD_ID_LEN) {
        return res.status(400).json({ error: 'invalid pod_id' })
      }
      rows = db.prepare(`
        SELECT id, pod_id, node_id, display_name, body, ts
        FROM chat_messages
        WHERE pod_id = ?
        ORDER BY ts DESC
        LIMIT ?
      `).all(podId, limit)
    } else {
      rows = db.prepare(`
        SELECT id, pod_id, node_id, display_name, body, ts
        FROM chat_messages
        WHERE pod_id IS NULL
        ORDER BY ts DESC
        LIMIT ?
      `).all(limit)
    }
    // Return in chronological order (oldest first) for UI append-ease
    res.json(rows.reverse())
  } catch (e) {
    log.error('chat', 'list failed', e)
    res.status(500).json({ error: 'list failed' })
  }
})

module.exports = router
