'use strict'
const express = require('express')
const router = express.Router()
const db = require('../../core/db')
const log = require('../../core/log')
const flags = require('../feature-flags')

function ensureFlag(req, res) {
  if (!flags.is('p7_smart_playlists')) {
    res.status(403).json({ error: 'feature disabled: p7_smart_playlists' })
    return false
  }
  return true
}

// GET /smart/pod-mix — up to 50 random tracks from "pod library" (tracks + collab_queue tracks)
router.get('/pod-mix', (req, res) => {
  if (!ensureFlag(req, res)) return
  try {
    const limit = Math.min(parseInt(req.query.limit) || 50, 50)
    // Union tracks present in tracks table OR referenced by collab_queue
    const rows = db.prepare(`
      SELECT DISTINCT t.id, t.title, t.artist, t.album, t.duration, t.format, t.art_hash
      FROM tracks t
      WHERE t.id IN (
        SELECT id FROM tracks
        UNION
        SELECT track_id FROM collab_queue
      )
      ORDER BY RANDOM()
      LIMIT ?
    `).all(limit)
    log.debug('smart-playlists', `pod-mix returned ${rows.length} tracks`)
    res.json(rows)
  } catch (e) {
    log.error('smart-playlists', 'pod-mix failed', e)
    res.status(500).json({ error: 'pod-mix failed' })
  }
})

// GET /smart/mood?energy=high|medium|low
router.get('/mood', (req, res) => {
  if (!ensureFlag(req, res)) return
  try {
    const energy = (req.query.energy || '').toLowerCase()
    const limit = Math.min(parseInt(req.query.limit) || 50, 200)
    const VALID = new Set(['high', 'medium', 'low'])
    if (!VALID.has(energy)) return res.status(400).json({ error: 'energy must be high|medium|low' })

    let bpmFilter
    if (energy === 'high') bpmFilter = 'ta.bpm > 120'
    else if (energy === 'medium') bpmFilter = 'ta.bpm >= 80 AND ta.bpm <= 120'
    else bpmFilter = 'ta.bpm < 80'

    const rows = db.prepare(`
      SELECT t.id, t.title, t.artist, t.album, t.duration, t.format, t.art_hash,
             ta.bpm, ta.musical_key
      FROM tracks t
      JOIN track_analysis ta ON ta.track_id = t.id
      WHERE ta.bpm IS NOT NULL AND ${bpmFilter}
      ORDER BY RANDOM()
      LIMIT ?
    `).all(limit)

    if (rows.length === 0) {
      // Fallback: random tracks
      const fallback = db.prepare(`
        SELECT id, title, artist, album, duration, format, art_hash, NULL as bpm, NULL as musical_key
        FROM tracks ORDER BY RANDOM() LIMIT ?
      `).all(limit)
      log.debug('smart-playlists', `mood ${energy} fallback (no analysis): ${fallback.length} tracks`)
      return res.json(fallback)
    }

    log.debug('smart-playlists', `mood ${energy}: ${rows.length} tracks`)
    res.json(rows)
  } catch (e) {
    log.error('smart-playlists', 'mood failed', e)
    res.status(500).json({ error: 'mood failed' })
  }
})

// GET /smart/similar/:track_id — up to 20 tracks with ±15 BPM and (if available) same key
router.get('/similar/:track_id', (req, res) => {
  if (!ensureFlag(req, res)) return
  try {
    const trackId = req.params.track_id
    const limit = Math.min(parseInt(req.query.limit) || 20, 50)

    const seed = db.prepare('SELECT bpm, musical_key FROM track_analysis WHERE track_id = ?').get(trackId)
    if (!seed || seed.bpm == null) {
      // Fallback: random tracks excluding seed
      const fallback = db.prepare(`
        SELECT t.id, t.title, t.artist, t.album, t.duration, t.format, t.art_hash,
               NULL as bpm, NULL as musical_key
        FROM tracks t WHERE t.id != ? ORDER BY RANDOM() LIMIT ?
      `).all(trackId, limit)
      log.debug('smart-playlists', `similar ${trackId}: no analysis, fallback ${fallback.length}`)
      return res.json(fallback)
    }

    const bpmLow = seed.bpm - 15
    const bpmHigh = seed.bpm + 15
    const params = [trackId, bpmLow, bpmHigh]
    let keyClause = ''
    if (seed.musical_key) {
      keyClause = 'AND (ta.musical_key = ? OR ta.musical_key IS NULL)'
      params.push(seed.musical_key)
    }
    params.push(limit)

    const rows = db.prepare(`
      SELECT t.id, t.title, t.artist, t.album, t.duration, t.format, t.art_hash,
             ta.bpm, ta.musical_key,
             ABS(ta.bpm - ${seed.bpm}) AS bpm_diff
      FROM tracks t
      JOIN track_analysis ta ON ta.track_id = t.id
      WHERE t.id != ? AND ta.bpm BETWEEN ? AND ? ${keyClause}
      ORDER BY bpm_diff ASC
      LIMIT ?
    `).all(...params)

    log.debug('smart-playlists', `similar ${trackId} (${seed.bpm} BPM): ${rows.length} matches`)
    res.json(rows)
  } catch (e) {
    log.error('smart-playlists', 'similar failed', e)
    res.status(500).json({ error: 'similar failed' })
  }
})

// GET /smart/smart-shuffle — full track list interleaved so adjacent BPM diff <= 20
router.get('/smart-shuffle', (req, res) => {
  if (!ensureFlag(req, res)) return
  try {
    const limit = Math.min(parseInt(req.query.limit) || 500, 1000)
    const rows = db.prepare(`
      SELECT t.id, t.title, t.artist, t.album, t.duration, t.format, t.art_hash,
             ta.bpm, ta.musical_key
      FROM tracks t
      LEFT JOIN track_analysis ta ON ta.track_id = t.id
      LIMIT ?
    `).all(limit)

    // Split into analyzed (with BPM) and unanalyzed
    const withBpm = rows.filter(r => r.bpm != null).sort((a, b) => a.bpm - b.bpm)
    const noBpm = rows.filter(r => r.bpm == null)

    // Greedy interleave: walk sorted-by-BPM list, but if next track is within 20 BPM, keep
    // walking; otherwise pick the closest from remaining. Since list is already sorted by BPM,
    // adjacent tracks differ by the smallest amount possible.
    const ordered = []
    const remaining = [...withBpm]
    if (remaining.length > 0) {
      ordered.push(remaining.shift())
      while (remaining.length > 0) {
        const last = ordered[ordered.length - 1]
        // Find the closest BPM to last
        let bestIdx = 0
        let bestDiff = Math.abs(remaining[0].bpm - last.bpm)
        for (let i = 1; i < remaining.length; i++) {
          const d = Math.abs(remaining[i].bpm - last.bpm)
          if (d < bestDiff) { bestDiff = d; bestIdx = i }
        }
        // If best within 20, take it; otherwise still take it (best available)
        ordered.push(remaining.splice(bestIdx, 1)[0])
      }
    }
    // Append unanalyzed at the end
    ordered.push(...noBpm)

    log.debug('smart-playlists', `smart-shuffle ordered ${ordered.length} tracks`)
    res.json(ordered)
  } catch (e) {
    log.error('smart-playlists', 'smart-shuffle failed', e)
    res.status(500).json({ error: 'smart-shuffle failed' })
  }
})

module.exports = router
