const express = require('express')
const router = express.Router()
const fs = require('fs')
const db = require('../../core/db')
const events = require('../events')
const log = require('../../core/log')

const MIME = {
  mp3: 'audio/mpeg', flac: 'audio/flac', wav: 'audio/wav',
  aac: 'audio/aac', ogg: 'audio/ogg', m4a: 'audio/mp4', opus: 'audio/opus'
}

router.get('/:track_id', (req, res) => {
  const track = db.prepare('SELECT path, format FROM tracks WHERE id = ?').get(req.params.track_id)
  if (!track) return res.status(404).json({ error: 'not found' })
  if (!fs.existsSync(track.path)) {
    log.warn('stream', `file missing on disk: ${track.path}`)
    return res.status(410).json({ error: 'file missing' })
  }

  // Record play (only on initial non-range or first-chunk request)
  const range = req.headers.range
  if (!range || range.startsWith('bytes=0-')) {
    try {
      db.prepare('INSERT INTO play_history (track_id, source_node_id, pod_id, played_ts) VALUES (?, ?, ?, ?)').run(
        req.params.track_id, req.podContext?.node_id || null, req.podContext?.pod_id || null, Date.now()
      )
      const meta = db.prepare('SELECT title, artist FROM tracks WHERE id = ?').get(req.params.track_id)
      events.emit('audio.track.started', { track_id: req.params.track_id, ...meta })
      log.info('stream', `play: ${meta?.title || req.params.track_id} (${meta?.artist || 'unknown'})`)
    } catch (e) {
      log.warn('stream', 'play history write failed', e)
    }
  }

  let stat
  try {
    stat = fs.statSync(track.path)
  } catch (e) {
    log.error('stream', `stat failed: ${track.path}`, e)
    return res.status(500).json({ error: 'cannot read file' })
  }

  const total = stat.size
  const mime = MIME[track.format] || 'audio/mpeg'

  res.setHeader('Accept-Ranges', 'bytes')
  res.setHeader('Content-Type', mime)

  if (range) {
    const [startStr, endStr] = range.replace(/bytes=/, '').split('-')
    const start = parseInt(startStr, 10) || 0
    const end = endStr ? parseInt(endStr, 10) : total - 1
    if (isNaN(start) || isNaN(end) || start < 0 || end < start || start >= total) {
      res.setHeader('Content-Range', `bytes */${total}`)
      return res.status(416).end()
    }
    const clampedEnd = Math.min(end, total - 1)
    const chunkSize = clampedEnd - start + 1
    res.setHeader('Content-Range', `bytes ${start}-${clampedEnd}/${total}`)
    res.setHeader('Content-Length', chunkSize)
    res.statusCode = 206
    fs.createReadStream(track.path, { start, end: clampedEnd }).pipe(res)
  } else {
    res.setHeader('Content-Length', total)
    res.statusCode = 200
    fs.createReadStream(track.path).pipe(res)
  }
})

module.exports = router
