'use strict'
const express = require('express')
const router = express.Router()
const db = require('../../core/db')
const log = require('../../core/log')
const { getStatus, queueAll, enqueue } = require('./index')

// GET /analysis/status — queue progress + counts
router.get('/status', (req, res) => {
  res.json(getStatus())
})

// POST /analysis/scan — queue all unanalyzed tracks
router.post('/scan', (req, res) => {
  const queued = queueAll()
  log.info('analysis', `scan triggered via API — ${queued} tracks queued`)
  res.json({ queued, ...getStatus() })
})

// GET /analysis/similar/:id — tracks similar by BPM & key
router.get('/similar/:id', (req, res) => {
  const analysis = db.prepare('SELECT bpm, musical_key FROM track_analysis WHERE track_id = ?').get(req.params.id)
  const track = db.prepare('SELECT artist FROM tracks WHERE id = ?').get(req.params.id)
  const limit = Math.min(parseInt(req.query.limit) || 10, 20)

  if (analysis?.bpm) {
    const margin = Math.max(8, Math.round(analysis.bpm * 0.06))
    const rows = db.prepare(`
      SELECT t.id, t.title, t.artist, t.album, t.duration, t.art_hash, t.format,
             ta.bpm, ta.musical_key AS key,
             ABS(COALESCE(ta.bpm, 0) - ?) AS bpm_diff
      FROM tracks t
      LEFT JOIN track_analysis ta ON ta.track_id = t.id
      WHERE t.id != ? AND ta.bpm BETWEEN ? AND ?
      ORDER BY bpm_diff ASC
      LIMIT ?
    `).all(analysis.bpm, req.params.id, analysis.bpm - margin, analysis.bpm + margin, limit)
    return res.json(rows)
  }

  // Fallback: same artist
  if (track?.artist) {
    const rows = db.prepare(`
      SELECT t.id, t.title, t.artist, t.album, t.duration, t.art_hash, t.format,
             ta.bpm, ta.musical_key AS key
      FROM tracks t
      LEFT JOIN track_analysis ta ON ta.track_id = t.id
      WHERE t.id != ? AND t.artist = ?
      ORDER BY RANDOM() LIMIT ?
    `).all(req.params.id, track.artist, limit)
    return res.json(rows)
  }

  res.json([])
})

// GET /analysis/:id/waveform — normalized 300-sample amplitude array (requires ffmpeg)
router.get('/:id/waveform', (req, res) => {
  const row = db.prepare('SELECT waveform FROM track_analysis WHERE track_id = ?').get(req.params.id)
  if (!row || !row.waveform) return res.status(404).json({ error: 'no waveform' })
  try {
    res.json({ samples: JSON.parse(row.waveform) })
  } catch (e) {
    log.warn('analysis', `waveform parse error for ${req.params.id}`)
    res.status(500).json({ error: 'waveform data corrupt' })
  }
})

// GET /analysis/:id — get cached analysis for one track
router.get('/:id', (req, res) => {
  const row = db.prepare('SELECT bpm, musical_key AS key, loudness, analyzed_ts FROM track_analysis WHERE track_id = ?').get(req.params.id)
  if (!row) return res.status(404).json({ error: 'not analyzed' })
  res.json(row)
})

// POST /analysis/:id — queue one track for analysis
router.post('/:id', (req, res) => {
  const track = db.prepare('SELECT id FROM tracks WHERE id = ?').get(req.params.id)
  if (!track) return res.status(404).json({ error: 'track not found' })
  // Clear existing so it gets reprocessed
  db.prepare('DELETE FROM track_analysis WHERE track_id = ?').run(req.params.id)
  enqueue([req.params.id])
  res.json({ ok: true, ...getStatus() })
})

module.exports = router
