'use strict'
const express = require('express')
const router = express.Router()
const db = require('../../core/db')
const log = require('../../core/log')
const events = require('../events')

router.get('/', (req, res) => {
  const items = db.prepare(`
    SELECT cq.id, cq.track_id, cq.added_by, cq.added_ts, cq.played_ts,
           t.title, t.artist, t.album, t.duration, t.art_hash, t.format
    FROM collab_queue cq
    LEFT JOIN tracks t ON t.id = cq.track_id
    WHERE cq.played_ts IS NULL
    ORDER BY cq.id ASC
  `).all()
  res.json(items)
})

router.post('/', (req, res) => {
  const { track_id, added_by } = req.body
  if (!track_id) return res.status(400).json({ error: 'track_id required' })

  const track = db.prepare('SELECT id, title, artist FROM tracks WHERE id = ?').get(track_id)
  if (!track) return res.status(404).json({ error: 'track not found' })

  const sourceNodeId = req.podContext?.node_id || null
  const result = db.prepare(
    'INSERT INTO collab_queue (track_id, source_node_id, added_by, added_ts) VALUES (?, ?, ?, ?)'
  ).run(track_id, sourceNodeId, added_by || null, Date.now())

  log.info('collab-queue', `added "${track.title}" by ${added_by || 'local'} (id=${result.lastInsertRowid})`)
  events.emit('queue.track.added', { id: result.lastInsertRowid, track_id, title: track.title, artist: track.artist, added_by: added_by || null })
  res.json({ id: result.lastInsertRowid, track_id, title: track.title })
})

router.delete('/:id', (req, res) => {
  const id = parseInt(req.params.id)
  if (isNaN(id)) return res.status(400).json({ error: 'invalid id' })
  const result = db.prepare('DELETE FROM collab_queue WHERE id = ? AND played_ts IS NULL').run(id)
  if (result.changes === 0) return res.status(404).json({ error: 'item not found or already played' })
  res.json({ ok: true })
})

router.post('/mark-played/:id', (req, res) => {
  const id = parseInt(req.params.id)
  if (isNaN(id)) return res.status(400).json({ error: 'invalid id' })
  db.prepare('UPDATE collab_queue SET played_ts = ? WHERE id = ?').run(Date.now(), id)
  res.json({ ok: true })
})

router.delete('/', (req, res) => {
  db.prepare('DELETE FROM collab_queue WHERE played_ts IS NULL').run()
  log.info('collab-queue', 'cleared')
  events.emit('queue.cleared', {})
  res.json({ ok: true })
})

module.exports = router
