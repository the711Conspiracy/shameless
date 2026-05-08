const express = require('express')
const http = require('http')
const path = require('path')
const { WebSocketServer } = require('ws')
const { bootstrap } = require('./core/identity')
const log = require('./core/log')
const libraryRoutes = require('./modules/library/routes')
const streamRoutes = require('./modules/stream/routes')
const playlistRoutes = require('./modules/playlists/routes')
const podRoutes = require('./modules/pods/routes')
const { podRouter } = require('./modules/pod-router')
const settingsRoutes = require('./modules/settings/routes')
const analysisRoutes = require('./modules/track-analysis/routes')
const collabQueueRoutes = require('./modules/collab-queue/routes')
const smartPlaylistsRoutes = require('./modules/smart-playlists/routes')
const listeningPartyRoutes = require('./modules/listening-party/routes')
const reactionsRoutes = require('./modules/reactions/routes')
const chatRoutes = require('./modules/chat/routes')
const multiRoomRoutes = require('./modules/multi-room/routes')
const offlineCacheRoutes = require('./modules/offline-cache/routes')
const discovery = require('./modules/discovery')
const events = require('./modules/events')

let nodeIdentity = null
let _httpServer = null
let _wss = null

async function start(httpPort = 7432) {
  nodeIdentity = await bootstrap()
  log.info('daemon', `node identity: ${nodeIdentity.node_id} (${nodeIdentity.display_name})`)
  discovery.start(nodeIdentity.node_id, nodeIdentity.display_name)

  const app = express()
  app.use(express.json())

  // Request logger
  app.use((req, res, next) => {
    const t = Date.now()
    res.on('finish', () => {
      const ms = Date.now() - t
      const lvl = res.statusCode >= 500 ? 'error' : res.statusCode >= 400 ? 'warn' : 'debug'
      log[lvl]('http', `${req.method} ${req.path} -> ${res.statusCode} (${ms}ms)`)
    })
    next()
  })

  app.use((req, res, next) => {
    res.setHeader('Access-Control-Allow-Origin', '*')
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Range, Pod-ID, Node-ID, Authorization, Timestamp')
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, PUT, PATCH, DELETE, OPTIONS')
    if (req.method === 'OPTIONS') return res.sendStatus(204)
    next()
  })

  app.get('/peers', (req, res) => {
    const dbCore = require('./core/db')
    const since = Date.now() - 30000  // online = seen in last 30s
    const peers = dbCore.prepare(`
      SELECT node_id, last_ip, last_port, last_seen_ts,
             (last_seen_ts > ?) as online
      FROM peers ORDER BY last_seen_ts DESC
    `).all(since)
    res.json(peers)
  })

  app.get('/ping', (req, res) => {
    res.json({ node_id: nodeIdentity.node_id, name: nodeIdentity.display_name, ts: Date.now() })
  })

  app.get('/identity', (req, res) => {
    res.json({
      node_id: nodeIdentity.node_id,
      pubkey: nodeIdentity.pubkey,
      cert: nodeIdentity.cert,
      display_name: nodeIdentity.display_name,
    })
  })

  app.get('/logs', (req, res) => {
    const n = Math.min(parseInt(req.query.n) || 200, 500)
    res.json({ entries: log.recent(n), log_path: log.logPath })
  })

  // Desktop web player UI
  app.get('/ui', (req, res) => res.sendFile(path.resolve(__dirname, '..', 'ui', 'index.html')))
  app.use('/ui', express.static(path.resolve(__dirname, '..', 'ui')))

  app.use(podRouter)
  app.use('/library', libraryRoutes)
  app.use('/stream', streamRoutes)
  app.use('/playlists', playlistRoutes)
  app.use('/pods', podRoutes)
  app.use('/settings', settingsRoutes)
  app.use('/analysis', analysisRoutes)
  app.use('/queue/collab', collabQueueRoutes)
  app.use('/smart', smartPlaylistsRoutes)
  app.use('/party', listeningPartyRoutes)
  app.use('/reactions', reactionsRoutes)
  app.use('/chat', chatRoutes)
  app.use('/multiroom', multiRoomRoutes)
  app.use('/offline', offlineCacheRoutes)

  app.get('/history', (req, res) => {
    const dbCore = require('./core/db')
    const limit = Math.min(parseInt(req.query.limit) || 50, 200)
    const rows = dbCore.prepare(`
      SELECT ph.played_ts, t.id, t.title, t.artist, t.album, t.format, t.art_hash
      FROM play_history ph JOIN tracks t ON t.id = ph.track_id
      ORDER BY ph.played_ts DESC LIMIT ?
    `).all(limit)
    res.json(rows)
  })

  app.post('/library/import', async (req, res) => {
    const { csv, playlist_name } = req.body
    if (!csv || typeof csv !== 'string') return res.status(400).json({ error: 'csv required' })
    const dbCore = require('./core/db')
    const cryptoNode = require('crypto')
    const fsLib = require('fs')
    const { __indexTrack } = require('./modules/library/routes')

    function parseCsv(raw) {
      const lines = raw.trim().split(/\r?\n/)
      if (lines.length < 2) return []
      const headers = lines[0].split('\t').length > 2 ? lines[0].split('\t') : lines[0].split(',')
      const delim = lines[0].split('\t').length > 2 ? '\t' : ','
      return lines.slice(1).map(line => {
        const vals = []
        let cur = '', inQ = false
        for (const ch of line + delim) {
          if (ch === '"') { inQ = !inQ }
          else if (ch === delim && !inQ) { vals.push(cur.trim()); cur = '' }
          else cur += ch
        }
        return Object.fromEntries(headers.map((h, i) => [h.trim(), vals[i] ?? '']))
      })
    }

    const rows = parseCsv(csv)
    const hasLocation = rows[0] && 'Location' in rows[0]
    const hasSpotifyId = rows[0] && 'Spotify ID' in rows[0]

    let indexed = 0, matched = 0
    const matchedIds = []

    if (hasLocation) {
      for (const row of rows) {
        const loc = (row['Location'] || '').replace(/^file:\/\//, '').replace(/%20/g, ' ')
        if (!loc || !fsLib.existsSync(loc)) continue
        try {
          const id = await __indexTrack(loc)
          if (id) { matchedIds.push(id); indexed++ }
        } catch (e) {
          log.warn('import', `skip ${loc}`, e)
        }
      }
    } else if (hasSpotifyId || 'Track Name' in (rows[0] || {})) {
      const allTracks = dbCore.prepare('SELECT id, title, artist FROM tracks').all()
      for (const row of rows) {
        const title = (row['Track Name'] || row['Name'] || '').toLowerCase().trim()
        const artist = (row['Artist Name'] || row['Artist'] || '').toLowerCase().trim()
        if (!title) continue
        const hit = allTracks.find(t =>
          (t.title || '').toLowerCase() === title &&
          (!artist || (t.artist || '').toLowerCase().includes(artist.split(',')[0].trim()))
        )
        if (hit) { matchedIds.push(hit.id); matched++ }
      }
    }

    let playlist_id = null
    if (matchedIds.length > 0 && playlist_name) {
      playlist_id = cryptoNode.randomUUID()
      dbCore.prepare('INSERT INTO playlists (id, name, pod_id, type, created_ts) VALUES (?, ?, NULL, ?, ?)')
        .run(playlist_id, playlist_name.trim(), 'manual', Date.now())
      matchedIds.forEach((tid, pos) => {
        dbCore.prepare('INSERT OR IGNORE INTO playlist_tracks (playlist_id, track_id, position) VALUES (?, ?, ?)')
          .run(playlist_id, tid, pos)
      })
    }

    res.json({ format: hasLocation ? 'apple_music' : 'spotify', rows: rows.length, indexed, matched, playlist_id })
  })

  app.get('/feed', (req, res) => {
    const dbCore = require('./core/db')
    const limit = Math.min(parseInt(req.query.limit) || 50, 200)
    const plays = dbCore.prepare(`
      SELECT 'play' AS type, ph.played_ts AS ts, ph.source_node_id,
             t.id AS track_id, t.title, t.artist, t.album, t.art_hash, NULL AS added_by
      FROM play_history ph JOIN tracks t ON t.id = ph.track_id
      ORDER BY ph.played_ts DESC LIMIT ?
    `).all(limit)
    const queued = dbCore.prepare(`
      SELECT 'queue_add' AS type, cq.added_ts AS ts, cq.source_node_id,
             t.id AS track_id, t.title, t.artist, t.album, t.art_hash, cq.added_by
      FROM collab_queue cq JOIN tracks t ON t.id = cq.track_id
      ORDER BY cq.added_ts DESC LIMIT ?
    `).all(Math.min(limit, 50))
    const feed = [...plays, ...queued].sort((a, b) => b.ts - a.ts).slice(0, limit)
    res.json(feed)
  })

  app.get('/stats', (req, res) => {
    const dbCore = require('./core/db')
    const weekAgo = Date.now() - 7 * 24 * 60 * 60 * 1000
    const trackCount = dbCore.prepare('SELECT COUNT(*) as n FROM tracks').get().n
    const artistCount = dbCore.prepare("SELECT COUNT(DISTINCT artist) as n FROM tracks WHERE artist IS NOT NULL AND artist != ''").get().n
    const albumCount = dbCore.prepare("SELECT COUNT(DISTINCT album) as n FROM tracks WHERE album IS NOT NULL AND album != ''").get().n
    const playCount = dbCore.prepare('SELECT COUNT(*) as n FROM play_history').get().n
    const topArtists = dbCore.prepare(`
      SELECT t.artist, COUNT(*) as plays FROM play_history ph
      JOIN tracks t ON t.id = ph.track_id
      WHERE t.artist IS NOT NULL AND t.artist != '' AND ph.played_ts > ?
      GROUP BY t.artist ORDER BY plays DESC LIMIT 5
    `).all(weekAgo)
    const recentPlay = dbCore.prepare(`
      SELECT t.title, t.artist FROM play_history ph
      JOIN tracks t ON t.id = ph.track_id
      ORDER BY ph.played_ts DESC LIMIT 1
    `).get()
    res.json({ trackCount, artistCount, albumCount, playCount, topArtists, recentPlay: recentPlay || null })
  })

  // Express unhandled error middleware (must be last, 4 args)
  app.use((err, req, res, next) => { // eslint-disable-line no-unused-vars
    log.error('http', `unhandled error on ${req.method} ${req.path}`, err)
    if (!res.headersSent) res.status(500).json({ error: 'Internal server error' })
  })

  _httpServer = http.createServer(app)

  const dbCore = require('./core/db')

  function broadcast(msg) {
    const data = JSON.stringify(msg)
    _wss.clients.forEach(c => { if (c.readyState === 1) c.send(data) })
  }

  events.on('peer.connected', (payload) => broadcast({ type: 'peer_discovered', payload }))
  events.on('library.track.added', (payload) => broadcast({ type: 'library_updated', payload }))
  events.on('library.track.removed', (payload) => broadcast({ type: 'library_updated', payload }))
  events.on('audio.track.started', (payload) => broadcast({ type: 'now_playing', payload }))
  events.on('analysis.track.done', (payload) => broadcast({ type: 'analysis_updated', payload }))
  events.on('queue.track.added', (payload) => broadcast({ type: 'queue_track_added', payload }))
  events.on('queue.cleared', (payload) => broadcast({ type: 'queue_cleared', payload }))
  events.on('analysis.complete', (payload) => {
    broadcast({ type: 'analysis_complete', payload })
    log.info('daemon', `analysis complete — ${payload.done} tracks analyzed`)
  })
  events.on('party.state', (payload) => broadcast({ type: 'party.state', payload }))
  events.on('party.created', (payload) => broadcast({ type: 'party.created', payload }))
  events.on('party.closed', (payload) => broadcast({ type: 'party.closed', payload }))
  events.on('reaction.added', (payload) => broadcast({ type: 'reaction.added', payload }))
  events.on('chat.message', (payload) => broadcast({ type: 'chat.message', payload }))
  events.on('identity.rotated', (payload) => broadcast({ type: 'identity.rotated', payload }))

  _wss = new WebSocketServer({ server: _httpServer })
  _wss.on('connection', (ws, req) => {
    const remoteIp = req.socket.remoteAddress
    log.debug('ws', `connection from ${remoteIp}`)
    ws.send(JSON.stringify({ type: 'hello', node_id: nodeIdentity.node_id }))
    ws.on('message', (data) => {
      try {
        const msg = JSON.parse(data)
        if (msg.type === 'ping') ws.send(JSON.stringify({ type: 'pong' }))
        if (msg.type === 'identify' && msg.node_id) {
          dbCore.prepare('INSERT OR REPLACE INTO peers (node_id, last_ip, last_seen_ts) VALUES (?, ?, ?)').run(msg.node_id, remoteIp, Date.now())
        }
      } catch (e) {
        log.warn('ws', 'bad message from ' + remoteIp, e)
      }
    })
    ws.on('error', (e) => log.warn('ws', `socket error from ${remoteIp}`, e))
  })
  _httpServer.on('error', (e) => {
    if (e.code === 'EADDRINUSE') log.error('daemon', `Port ${httpPort} already in use — kill the other instance first`)
    else log.error('daemon', 'HTTP server error', e)
  })
  _wss.on('error', (e) => { if (e.code !== 'EADDRINUSE') log.error('ws', 'WebSocket server error', e) })

  _httpServer.listen(httpPort, '0.0.0.0', () => {
    log.info('daemon', `listening on :${httpPort}`)
    log.info('daemon', `log file: ${log.logPath}`)
    console.log(`shamlss http:${httpPort}`)
  })

  return { app, httpServer: _httpServer }
}

async function stop() {
  log.info('daemon', 'shutting down')
  discovery.stop()
  await Promise.allSettled([
    _wss ? new Promise(r => _wss.close(r)) : Promise.resolve(),
    _httpServer ? new Promise(r => _httpServer.close(r)) : Promise.resolve()
  ])
}

process.on('SIGTERM', async () => { await stop(); process.exit(0) })
process.on('SIGINT',  async () => { await stop(); process.exit(0) })

process.on('uncaughtException', (err) => {
  log.error('daemon', 'uncaught exception', err)
  process.exit(1)
})
process.on('unhandledRejection', (reason) => {
  log.error('daemon', 'unhandled rejection', reason instanceof Error ? reason : new Error(String(reason)))
})

module.exports = { start, stop }

if (require.main === module) {
  start().catch(err => {
    log.error('daemon', 'failed to start', err)
    process.exit(1)
  })
}
