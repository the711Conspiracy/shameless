'use strict'
const express = require('express')
const router = express.Router()
const fs = require('fs')
const path = require('path')
const os = require('os')
const db = require('../../core/db')
const log = require('../../core/log')
const flags = require('../feature-flags')

const CACHE_DIR = path.join(os.homedir(), '.shamlss', 'cache')

const MIME = {
  mp3: 'audio/mpeg', flac: 'audio/flac', wav: 'audio/wav',
  aac: 'audio/aac', ogg: 'audio/ogg', m4a: 'audio/mp4', opus: 'audio/opus'
}

function ensureFlag(req, res) {
  if (!flags.is('p10_offline')) {
    res.status(403).json({ error: 'feature disabled: p10_offline' })
    return false
  }
  return true
}

function ensureCacheDir() {
  if (!fs.existsSync(CACHE_DIR)) fs.mkdirSync(CACHE_DIR, { recursive: true })
}

// Sanitize track id for use as a filename. We treat the id as opaque so reject anything with
// path separators or traversal characters. better-sqlite3 randomUUIDs are guaranteed safe but
// imported tracks may have arbitrary ids — be defensive.
function sanitizeTrackId(id) {
  if (typeof id !== 'string') return null
  if (id.length === 0 || id.length > 128) return null
  if (!/^[A-Za-z0-9._-]+$/.test(id)) return null
  return id
}

function sanitizeExt(format) {
  if (typeof format !== 'string') return 'bin'
  const f = format.toLowerCase()
  if (!/^[a-z0-9]{1,8}$/.test(f)) return 'bin'
  return f
}

function cachePathFor(trackId, ext) {
  const safe = sanitizeTrackId(trackId)
  if (!safe) return null
  const safeExt = sanitizeExt(ext)
  const candidate = path.join(CACHE_DIR, `${safe}.${safeExt}`)
  // Final guard: resolved path must remain inside CACHE_DIR
  const resolved = path.resolve(candidate)
  const resolvedDir = path.resolve(CACHE_DIR)
  if (!resolved.startsWith(resolvedDir + path.sep) && resolved !== resolvedDir) return null
  return resolved
}

// GET /offline — list cached tracks
router.get('/', (req, res) => {
  if (!ensureFlag(req, res)) return
  try {
    const rows = db.prepare(`
      SELECT oc.track_id, oc.file_path, oc.file_size, oc.cached_ts,
             t.title, t.artist, t.album, t.format, t.duration, t.art_hash
      FROM offline_cache oc
      LEFT JOIN tracks t ON t.id = oc.track_id
      ORDER BY oc.cached_ts DESC
    `).all()
    res.json(rows)
  } catch (e) {
    log.error('offline-cache', 'list failed', e)
    res.status(500).json({ error: 'list failed' })
  }
})

// POST /offline/cache — copy track file to cache directory
router.post('/cache', (req, res) => {
  if (!ensureFlag(req, res)) return
  const { track_id } = req.body || {}
  const safeId = sanitizeTrackId(track_id)
  if (!safeId) return res.status(400).json({ error: 'invalid track_id' })

  try {
    const track = db.prepare('SELECT id, path, format FROM tracks WHERE id = ?').get(safeId)
    if (!track) return res.status(404).json({ error: 'track not found' })
    if (!track.path || !fs.existsSync(track.path)) {
      log.warn('offline-cache', `source missing on disk for ${safeId}: ${track.path}`)
      return res.status(410).json({ error: 'source file missing' })
    }

    ensureCacheDir()
    const dest = cachePathFor(safeId, track.format)
    if (!dest) return res.status(400).json({ error: 'invalid cache path' })

    log.info('offline-cache', `caching ${safeId} -> ${dest}`)
    fs.copyFileSync(track.path, dest)
    const stat = fs.statSync(dest)

    db.prepare(`
      INSERT OR REPLACE INTO offline_cache (track_id, file_path, file_size, cached_ts)
      VALUES (?, ?, ?, ?)
    `).run(safeId, dest, stat.size, Date.now())

    log.info('offline-cache', `cached ${safeId} (${stat.size} bytes)`)
    res.status(201).json({ track_id: safeId, file_path: dest, file_size: stat.size })
  } catch (e) {
    log.error('offline-cache', `cache failed for ${safeId}`, e)
    res.status(500).json({ error: 'cache failed' })
  }
})

// DELETE /offline/cache/:track_id — remove cached file + record
router.delete('/cache/:track_id', (req, res) => {
  if (!ensureFlag(req, res)) return
  const safeId = sanitizeTrackId(req.params.track_id)
  if (!safeId) return res.status(400).json({ error: 'invalid track_id' })

  try {
    const row = db.prepare('SELECT file_path FROM offline_cache WHERE track_id = ?').get(safeId)
    if (!row) return res.status(404).json({ error: 'not cached' })

    // Re-validate the stored path is still inside CACHE_DIR before unlink
    const resolved = path.resolve(row.file_path)
    const resolvedDir = path.resolve(CACHE_DIR)
    if (resolved.startsWith(resolvedDir + path.sep) && fs.existsSync(resolved)) {
      try { fs.unlinkSync(resolved) } catch (e) { log.warn('offline-cache', `unlink failed: ${resolved}`, e) }
    } else {
      log.warn('offline-cache', `refusing to unlink path outside cache dir: ${row.file_path}`)
    }

    db.prepare('DELETE FROM offline_cache WHERE track_id = ?').run(safeId)
    log.info('offline-cache', `removed ${safeId}`)
    res.json({ ok: true, track_id: safeId })
  } catch (e) {
    log.error('offline-cache', `delete failed for ${safeId}`, e)
    res.status(500).json({ error: 'delete failed' })
  }
})

// GET /offline/stream/:track_id — stream from cached file with Range support
router.get('/stream/:track_id', (req, res) => {
  if (!ensureFlag(req, res)) return
  const safeId = sanitizeTrackId(req.params.track_id)
  if (!safeId) return res.status(400).json({ error: 'invalid track_id' })

  try {
    const row = db.prepare('SELECT file_path FROM offline_cache WHERE track_id = ?').get(safeId)
    if (!row) return res.status(404).json({ error: 'not cached' })

    const resolved = path.resolve(row.file_path)
    const resolvedDir = path.resolve(CACHE_DIR)
    if (!resolved.startsWith(resolvedDir + path.sep) && resolved !== resolvedDir) {
      log.warn('offline-cache', `refusing to stream path outside cache dir: ${row.file_path}`)
      return res.status(403).json({ error: 'invalid cache path' })
    }
    if (!fs.existsSync(resolved)) {
      log.warn('offline-cache', `cached file missing: ${resolved}`)
      return res.status(404).json({ error: 'cached file missing' })
    }

    let stat
    try {
      stat = fs.statSync(resolved)
    } catch (e) {
      log.error('offline-cache', `stat failed: ${resolved}`, e)
      return res.status(500).json({ error: 'cannot read file' })
    }

    const total = stat.size
    const ext = path.extname(resolved).slice(1).toLowerCase()
    const mime = MIME[ext] || 'audio/mpeg'

    res.setHeader('Accept-Ranges', 'bytes')
    res.setHeader('Content-Type', mime)

    const range = req.headers.range
    if (range) {
      const [startStr, endStr] = range.replace(/bytes=/, '').split('-')
      const start = parseInt(startStr, 10) || 0
      const end = endStr ? parseInt(endStr, 10) : total - 1
      if (start >= total || end >= total || start > end) {
        res.setHeader('Content-Range', `bytes */${total}`)
        return res.status(416).end()
      }
      const chunkSize = end - start + 1
      res.setHeader('Content-Range', `bytes ${start}-${end}/${total}`)
      res.setHeader('Content-Length', chunkSize)
      res.statusCode = 206
      fs.createReadStream(resolved, { start, end }).pipe(res)
    } else {
      res.setHeader('Content-Length', total)
      res.statusCode = 200
      fs.createReadStream(resolved).pipe(res)
    }
  } catch (e) {
    log.error('offline-cache', `stream failed for ${safeId}`, e)
    res.status(500).json({ error: 'stream failed' })
  }
})

module.exports = router
