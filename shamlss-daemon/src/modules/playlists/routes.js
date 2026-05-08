const express = require('express')
const router = express.Router()
const crypto = require('crypto')
const db = require('../../core/db')
const log = require('../../core/log')

router.get('/', (req, res) => {
  const playlists = db.prepare(`
    SELECT p.id, p.name, p.type, p.created_ts, COUNT(pt.track_id) as track_count
    FROM playlists p
    LEFT JOIN playlist_tracks pt ON pt.playlist_id = p.id
    WHERE p.pod_id IS NULL
    GROUP BY p.id ORDER BY p.created_ts DESC
  `).all()
  res.json(playlists)
})

router.post('/', (req, res) => {
  const { name } = req.body
  if (!name?.trim()) return res.status(400).json({ error: 'name required' })
  const id = crypto.randomUUID()
  db.prepare('INSERT INTO playlists (id, name, pod_id, type, created_ts) VALUES (?, ?, NULL, ?, ?)').run(id, name.trim(), 'manual', Date.now())
  log.info('playlists', `created "${name.trim()}" id=${id}`)
  res.status(201).json({ id, name: name.trim() })
})

router.get('/:id', (req, res) => {
  const pl = db.prepare('SELECT * FROM playlists WHERE id = ? AND pod_id IS NULL').get(req.params.id)
  if (!pl) return res.status(404).json({ error: 'not found' })
  const tracks = db.prepare(`
    SELECT t.id, t.title, t.artist, t.album, t.format, t.duration, t.art_hash, pt.position
    FROM playlist_tracks pt JOIN tracks t ON t.id = pt.track_id
    WHERE pt.playlist_id = ? ORDER BY pt.position
  `).all(req.params.id)
  res.json({ ...pl, tracks })
})

router.delete('/:id', (req, res) => {
  db.prepare('DELETE FROM playlist_tracks WHERE playlist_id = ?').run(req.params.id)
  db.prepare('DELETE FROM playlists WHERE id = ? AND pod_id IS NULL').run(req.params.id)
  log.info('playlists', `deleted playlist ${req.params.id}`)
  res.json({ ok: true })
})

router.patch('/:id', (req, res) => {
  const { name } = req.body
  if (!name?.trim()) return res.status(400).json({ error: 'name required' })
  db.prepare('UPDATE playlists SET name = ? WHERE id = ? AND pod_id IS NULL').run(name.trim(), req.params.id)
  res.json({ ok: true })
})

router.post('/:id/tracks', (req, res) => {
  const { track_id } = req.body
  if (!track_id) return res.status(400).json({ error: 'track_id required' })
  const track = db.prepare('SELECT id FROM tracks WHERE id = ?').get(track_id)
  if (!track) return res.status(404).json({ error: 'track not found' })

  const last = db.prepare('SELECT MAX(position) as pos FROM playlist_tracks WHERE playlist_id = ?').get(req.params.id)
  const position = (last?.pos ?? -1) + 1
  db.prepare('INSERT OR IGNORE INTO playlist_tracks (playlist_id, track_id, position) VALUES (?, ?, ?)').run(req.params.id, track_id, position)
  res.status(201).json({ ok: true, position })
})

router.get('/:id/export.m3u', (req, res) => {
  const pl = db.prepare('SELECT * FROM playlists WHERE id = ? AND pod_id IS NULL').get(req.params.id)
  if (!pl) return res.status(404).json({ error: 'not found' })
  const tracks = db.prepare(`
    SELECT t.path, t.title, t.artist, t.duration
    FROM playlist_tracks pt JOIN tracks t ON t.id = pt.track_id
    WHERE pt.playlist_id = ? ORDER BY pt.position
  `).all(req.params.id)

  const lines = ['#EXTM3U', `#PLAYLIST:${pl.name}`]
  for (const t of tracks) {
    const dur = t.duration ? Math.round(t.duration / 1000) : -1
    const info = t.artist ? `${t.artist} - ${t.title || 'Unknown'}` : (t.title || 'Unknown')
    lines.push(`#EXTINF:${dur},${info}`)
    lines.push(t.path)
  }

  res.setHeader('Content-Type', 'audio/x-mpegurl; charset=utf-8')
  res.setHeader('Content-Disposition', `attachment; filename="${pl.name.replace(/[^\w\s-]/g, '')}.m3u"`)
  res.send(lines.join('\r\n'))
})

router.delete('/:id/tracks/:track_id', (req, res) => {
  db.prepare('DELETE FROM playlist_tracks WHERE playlist_id = ? AND track_id = ?').run(req.params.id, req.params.track_id)
  // Resequence positions
  const remaining = db.prepare('SELECT track_id FROM playlist_tracks WHERE playlist_id = ? ORDER BY position').all(req.params.id)
  const reseq = db.prepare('UPDATE playlist_tracks SET position = ? WHERE playlist_id = ? AND track_id = ?')
  remaining.forEach((r, i) => reseq.run(i, req.params.id, r.track_id))
  res.json({ ok: true })
})

module.exports = router
