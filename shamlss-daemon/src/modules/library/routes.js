const express = require('express')
const router = express.Router()
const path = require('path')
const fs = require('fs')
const crypto = require('crypto')
const mm = require('music-metadata')
const db = require('../../core/db')
const events = require('../events')
const log = require('../../core/log')

const AUDIO_EXTS = new Set(['.mp3', '.flac', '.wav', '.aac', '.ogg', '.m4a', '.opus'])
const _watchers = new Map()

function watchFolder(folderPath) {
  if (_watchers.has(folderPath) || !fs.existsSync(folderPath)) return
  try {
    const watcher = fs.watch(folderPath, { recursive: true }, async (event, filename) => {
      if (!filename) return
      const ext = path.extname(filename).toLowerCase()
      if (!AUDIO_EXTS.has(ext)) return
      const full = path.join(folderPath, filename)
      if (event === 'rename') {
        if (fs.existsSync(full)) {
          try {
            await indexTrack(full)
            events.emit('library.track.added', { folder_path: folderPath, file: full })
          } catch (e) {
            log.warn('library', `watcher index failed: ${full}`, e)
          }
        } else {
          db.prepare('DELETE FROM tracks WHERE path = ?').run(full)
          events.emit('library.track.removed', { folder_path: folderPath, file: full })
        }
      }
    })
    watcher.on('error', (e) => {
      log.warn('library', `watcher error on ${folderPath}`, e)
      _watchers.delete(folderPath)
    })
    _watchers.set(folderPath, watcher)
    log.debug('library', `watching ${folderPath}`)
  } catch (e) {
    log.warn('library', `failed to watch ${folderPath}`, e)
  }
}

// Restore watchers for all already-registered folders on startup
;(function restoreWatchers() {
  try {
    const folders = db.prepare('SELECT DISTINCT folder_path FROM pod_scopes').all()
    for (const { folder_path } of folders) watchFolder(folder_path)
    if (folders.length > 0) log.info('library', `restored watchers for ${folders.length} folder(s)`)
  } catch (e) {
    log.error('library', 'failed to restore watchers', e)
  }
})()

function scanFolder(folderPath, tracks = []) {
  if (!fs.existsSync(folderPath)) return tracks
  try {
    for (const entry of fs.readdirSync(folderPath, { withFileTypes: true })) {
      const full = path.join(folderPath, entry.name)
      if (entry.isDirectory()) {
        scanFolder(full, tracks)
      } else if (AUDIO_EXTS.has(path.extname(entry.name).toLowerCase())) {
        tracks.push(full)
      }
    }
  } catch (e) {
    log.warn('library', `scan error in ${folderPath}`, e)
  }
  return tracks
}

async function indexTrack(filePath) {
  const stat = fs.statSync(filePath)
  const fileHash = crypto.createHash('sha256')
    .update(filePath + stat.size + stat.mtimeMs)
    .digest('hex')
  const ext = path.extname(filePath).slice(1).toLowerCase()
  const baseName = path.basename(filePath, path.extname(filePath))

  const existing = db.prepare('SELECT id FROM tracks WHERE file_hash = ?').get(fileHash)
  if (existing) {
    db.prepare('UPDATE tracks SET path = ? WHERE id = ?').run(filePath, existing.id)
    return existing.id
  }

  let title = baseName, artist = null, album = null, year = null, genre = null
  let duration = null, bitrate = null, artHash = null, loudness = null, replayGain = null
  let _embeddedBpm = null, _embeddedKey = null

  try {
    const meta = await mm.parseFile(filePath, { duration: true, skipCovers: false })
    const t = meta.common
    const f = meta.format
    title = t.title || baseName
    artist = t.artist || t.albumartist || null
    album = t.album || null
    year = t.year || null
    genre = t.genre?.[0] || null
    duration = f.duration ? Math.round(f.duration * 1000) : null
    bitrate = f.bitrate ? Math.round(f.bitrate / 1000) : null
    replayGain = t.replayGainTrackGain?.dB ?? null
    loudness = f.loudness ?? null
    _embeddedBpm = t.bpm ? Math.round(t.bpm) : null
    _embeddedKey = t.key || null

    if (t.picture?.length > 0) {
      const pic = t.picture[0]
      artHash = crypto.createHash('sha256').update(pic.data).digest('hex')
      const artDir = path.join(require('os').homedir(), '.shamlss', 'art')
      if (!fs.existsSync(artDir)) fs.mkdirSync(artDir, { recursive: true })
      const artPath = path.join(artDir, artHash + '.jpg')
      if (!fs.existsSync(artPath)) fs.writeFileSync(artPath, pic.data)
    }
  } catch (e) {
    log.debug('library', `metadata parse failed for ${path.basename(filePath)}: ${e.message}`)
  }

  // Fallback: look for folder.jpg/cover.jpg if no embedded art
  if (!artHash) {
    const dir = path.dirname(filePath)
    for (const name of ['folder.jpg', 'cover.jpg', 'album.jpg', 'front.jpg', 'Cover.jpg', 'Folder.jpg']) {
      const candidate = path.join(dir, name)
      if (fs.existsSync(candidate)) {
        try {
          const data = fs.readFileSync(candidate)
          artHash = crypto.createHash('sha256').update(data).digest('hex')
          const artDir = path.join(require('os').homedir(), '.shamlss', 'art')
          if (!fs.existsSync(artDir)) fs.mkdirSync(artDir, { recursive: true })
          const artPath = path.join(artDir, artHash + '.jpg')
          if (!fs.existsSync(artPath)) fs.writeFileSync(artPath, data)
        } catch (e) {
          log.debug('library', `folder art read failed: ${candidate}`, e)
          artHash = null
        }
        break
      }
    }
  }

  const id = crypto.randomUUID()
  db.prepare(`
    INSERT INTO tracks (id, path, title, artist, album, year, genre, duration, bitrate, format, art_hash, file_hash, loudness, replay_gain, indexed_ts)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `).run(id, filePath, title, artist, album, year, genre, duration, bitrate, ext, artHash, fileHash, loudness, replayGain, Date.now())

  // Store embedded BPM/key immediately — saves a full analysis pass for tagged tracks
  if (_embeddedBpm || _embeddedKey) {
    db.prepare('INSERT OR IGNORE INTO track_analysis (track_id, bpm, musical_key, analyzed_ts) VALUES (?, ?, ?, ?)')
      .run(id, _embeddedBpm, _embeddedKey, Date.now())
  }

  return id
}

router.post('/folders', async (req, res) => {
  const { folder_path } = req.body
  if (!folder_path) return res.status(400).json({ error: 'folder_path required' })

  const node = db.prepare('SELECT node_id FROM nodes LIMIT 1').get()
  if (!node) return res.status(500).json({ error: 'no node identity' })

  if (!require('fs').existsSync(folder_path)) {
    return res.status(400).json({ error: 'folder not found: ' + folder_path })
  }

  const exists = db.prepare('SELECT 1 FROM pod_scopes WHERE folder_path = ?').get(folder_path)
  if (!exists) {
    db.prepare('INSERT OR IGNORE INTO pod_scopes (pod_id, folder_path) VALUES (?, ?)').run('local', folder_path)
  }

  log.info('library', `scanning ${folder_path}`)
  const files = scanFolder(folder_path)
  log.info('library', `found ${files.length} audio files in ${folder_path}`)

  let indexed = 0, skipped = 0
  for (const f of files) {
    try {
      await indexTrack(f)
      indexed++
    } catch (e) {
      skipped++
      log.warn('library', `index failed: ${f}`, e)
    }
  }

  log.info('library', `indexed ${indexed} tracks, skipped ${skipped} from ${folder_path}`)

  if (indexed > 0) {
    try { events.emit('library.track.added', { folder_path, indexed }) } catch (e) {
      log.warn('library', 'event emit failed', e)
    }
  }
  watchFolder(folder_path)
  res.json({ folder_path, files_found: files.length, indexed, skipped })
})

router.get('/folders', (req, res) => {
  const folders = db.prepare('SELECT folder_path FROM pod_scopes WHERE pod_id = ?').all('local')
  res.json(folders.map(f => f.folder_path))
})

router.get('/tracks', (req, res) => {
  const ctx = req.podContext
  if (ctx?.visibility === 'hidden') return res.json([])

  const { q, artist, album } = req.query
  const limit = Math.min(parseInt(req.query.limit) || 1000, 2000)

  let sql, params
  if (ctx?.visibility === 'folders') {
    const scopes = db.prepare('SELECT folder_path FROM pod_scopes WHERE pod_id = ?').all(ctx.pod_id)
    if (scopes.length === 0) return res.json([])
    const all = db.prepare('SELECT id, title, artist, album, format, duration, bitrate, art_hash, replay_gain, path FROM tracks ORDER BY artist, album, title').all()
    const allowed = scopes.map(s => s.folder_path.replace(/\\/g, '/').replace(/\/$/, ''))
    let tracks = all.filter(t => {
      const tp = (t.path || '').replace(/\\/g, '/')
      return allowed.some(scope => tp.startsWith(scope))
    }).map(({ path: _, ...rest }) => rest)
    if (q) {
      const lq = q.toLowerCase()
      tracks = tracks.filter(t =>
        (t.title || '').toLowerCase().includes(lq) ||
        (t.artist || '').toLowerCase().includes(lq) ||
        (t.album || '').toLowerCase().includes(lq)
      )
    }
    if (artist) tracks = tracks.filter(t => (t.artist || '').toLowerCase().includes(artist.toLowerCase()))
    if (album) tracks = tracks.filter(t => (t.album || '').toLowerCase().includes(album.toLowerCase()))
    return res.json(tracks.slice(0, limit))
  }

  const conditions = []
  params = []
  if (q) {
    conditions.push('(LOWER(title) LIKE ? OR LOWER(artist) LIKE ? OR LOWER(album) LIKE ?)')
    const lq = `%${q.toLowerCase()}%`
    params.push(lq, lq, lq)
  }
  if (artist) { conditions.push('LOWER(artist) LIKE ?'); params.push(`%${artist.toLowerCase()}%`) }
  if (album) { conditions.push('LOWER(album) LIKE ?'); params.push(`%${album.toLowerCase()}%`) }

  const where = conditions.length ? `WHERE ${conditions.join(' AND ')}` : ''
  sql = `SELECT id, title, artist, album, format, duration, bitrate, art_hash, replay_gain
         FROM tracks ${where} ORDER BY artist, album, title LIMIT ?`
  params.push(limit)

  res.json(db.prepare(sql).all(...params))
})

const FOLDER_ART_NAMES = ['folder.jpg', 'cover.jpg', 'album.jpg', 'front.jpg', 'artwork.jpg', 'Folder.jpg', 'Cover.jpg', 'Album.jpg']

router.get('/art/:track_id', (req, res) => {
  const track = db.prepare('SELECT art_hash, path FROM tracks WHERE id = ?').get(req.params.track_id)
  if (!track) return res.status(404).end()

  if (track.art_hash) {
    const artPath = path.join(require('os').homedir(), '.shamlss', 'art', track.art_hash + '.jpg')
    if (fs.existsSync(artPath)) {
      res.setHeader('Content-Type', 'image/jpeg')
      res.setHeader('Cache-Control', 'public, max-age=86400')
      return fs.createReadStream(artPath).pipe(res)
    }
  }

  if (track.path) {
    const dir = path.dirname(track.path)
    for (const name of FOLDER_ART_NAMES) {
      const candidate = path.join(dir, name)
      if (fs.existsSync(candidate)) {
        res.setHeader('Content-Type', 'image/jpeg')
        res.setHeader('Cache-Control', 'public, max-age=3600')
        return fs.createReadStream(candidate).pipe(res)
      }
    }
  }

  res.status(404).end()
})

router.get('/lyrics/:track_id', (req, res) => {
  const track = db.prepare('SELECT path FROM tracks WHERE id = ?').get(req.params.track_id)
  if (!track) return res.status(404).end()

  const base = track.path.replace(/\.[^.]+$/, '')
  const lrcPath = base + '.lrc'
  if (fs.existsSync(lrcPath)) {
    const raw = fs.readFileSync(lrcPath, 'utf8')
    return res.json({ source: 'lrc', lines: parseLRC(raw) })
  }

  mm.parseFile(track.path, { skipCovers: true }).then(meta => {
    const lyrics = meta.common.lyrics?.[0] || meta.common.unsynchronisedLyrics
    if (!lyrics) return res.status(404).end()
    if (typeof lyrics === 'string') {
      return res.json({ source: 'embedded', lines: lyrics.split('\n').map(t => ({ text: t })) })
    }
    res.json({ source: 'embedded', lines: [{ text: lyrics }] })
  }).catch((e) => {
    log.debug('library', `lyrics parse failed: ${track.path}`, e)
    res.status(404).end()
  })
})

function parseLRC(raw) {
  const lines = []
  for (const line of raw.split('\n')) {
    const m = line.match(/^\[(\d+):(\d+)\.(\d+)\](.*)$/)
    if (m) {
      const ms = parseInt(m[1]) * 60000 + parseInt(m[2]) * 1000 + parseInt(m[3]) * 10
      lines.push({ time_ms: ms, text: m[4].trim() })
    }
  }
  return lines.sort((a, b) => a.time_ms - b.time_ms)
}

// F59 Podcast/Audiobook — type tagging, chapters, resume
router.patch('/tracks/:id', (req, res) => {
  const { type } = req.body || {}
  if (!type || !['music', 'podcast', 'audiobook'].includes(type)) {
    return res.status(400).json({ error: 'type must be music, podcast, or audiobook' })
  }
  const track = db.prepare('SELECT id FROM tracks WHERE id = ?').get(req.params.id)
  if (!track) return res.status(404).json({ error: 'not found' })
  db.prepare('UPDATE tracks SET type = ? WHERE id = ?').run(type, req.params.id)
  log.info('library', `track ${req.params.id} type -> ${type}`)
  res.json({ id: req.params.id, type })
})

router.get('/tracks/:id/chapters', (req, res) => {
  const track = db.prepare('SELECT id FROM tracks WHERE id = ?').get(req.params.id)
  if (!track) return res.status(404).json({ error: 'not found' })
  const chapters = db.prepare('SELECT position_ms, title FROM track_chapters WHERE track_id = ? ORDER BY position_ms').all(req.params.id)
  res.json(chapters)
})

router.post('/tracks/:id/resume', (req, res) => {
  const { position_ms } = req.body || {}
  if (typeof position_ms !== 'number' || position_ms < 0) {
    return res.status(400).json({ error: 'position_ms required' })
  }
  db.prepare('INSERT OR REPLACE INTO track_resume (track_id, position_ms, updated_ts) VALUES (?, ?, ?)').run(req.params.id, position_ms, Date.now())
  log.debug('library', `resume saved: ${req.params.id} @ ${position_ms}ms`)
  res.json({ ok: true })
})

router.get('/tracks/:id/resume', (req, res) => {
  const row = db.prepare('SELECT position_ms, updated_ts FROM track_resume WHERE track_id = ?').get(req.params.id)
  if (!row) return res.json({ position_ms: 0 })
  res.json(row)
})

// Legacy alias — kept for any existing callers
router.get('/analyze/:track_id', (req, res) => {
  const row = db.prepare('SELECT bpm, musical_key AS key, loudness, analyzed_ts FROM track_analysis WHERE track_id = ?').get(req.params.track_id)
  if (row) return res.json({ ...row, cached: true })
  res.status(404).json({ error: 'not analyzed yet — POST /analysis/:id to queue' })
})

router.delete('/folders', (req, res) => {
  const { folder_path } = req.body
  if (!folder_path) return res.status(400).json({ error: 'folder_path required' })
  db.prepare('DELETE FROM pod_scopes WHERE folder_path = ? AND pod_id = ?').run(folder_path, 'local')
  db.prepare("DELETE FROM tracks WHERE path LIKE ?").run(folder_path.replace(/\\/g, '/').replace(/\/$/, '') + '%')
  db.prepare("DELETE FROM tracks WHERE path LIKE ?").run(folder_path.replace(/\/$/, '') + '%')
  const w = _watchers.get(folder_path)
  if (w) {
    try { w.close() } catch (e) { log.warn('library', `watcher close failed: ${folder_path}`, e) }
    _watchers.delete(folder_path)
  }
  try { events.emit('library.track.removed', { folder_path }) } catch (e) {
    log.warn('library', 'event emit failed', e)
  }
  log.info('library', `removed folder ${folder_path}`)
  res.json({ ok: true })
})

module.exports = router
module.exports.__indexTrack = indexTrack
