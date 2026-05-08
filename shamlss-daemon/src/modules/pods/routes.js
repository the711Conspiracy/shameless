const express = require('express')
const router = express.Router()
const crypto = require('crypto')
const os = require('os')
const db = require('../../core/db')
const cryptoModule = require('../crypto')
const events = require('../events')
const log = require('../../core/log')

function getLanIp() {
  for (const ifaces of Object.values(os.networkInterfaces())) {
    for (const iface of ifaces) {
      if (iface.family === 'IPv4' && !iface.internal) return iface.address
    }
  }
  return '127.0.0.1'
}

// POST /pods/identity/rotate — rotate this node's ed25519 keypair (F11)
router.post('/identity/rotate', async (req, res) => {
  try {
    log.info('identity', 'rotating node keypair')
    await cryptoModule.init()
    const existing = db.prepare('SELECT node_id, display_name, created_ts FROM nodes LIMIT 1').get()
    if (!existing) return res.status(500).json({ error: 'no node identity' })

    const fresh = cryptoModule.generateNodeIdentity()
    const tx = db.transaction(() => {
      db.prepare('DELETE FROM nodes WHERE node_id = ?').run(existing.node_id)
      db.prepare(
        'INSERT INTO nodes (node_id, pubkey, cert, display_name, created_ts) VALUES (?, ?, ?, ?, ?)'
      ).run(fresh.node_id, fresh.pubkey, fresh.cert, existing.display_name, existing.created_ts || Date.now())
    })
    tx()

    events.emit('identity.rotated', {
      old_node_id: existing.node_id,
      new_node_id: fresh.node_id,
      pubkey: fresh.pubkey
    })
    log.info('identity', `rotated ${existing.node_id} -> ${fresh.node_id}`)
    res.json({ node_id: fresh.node_id, pubkey: fresh.pubkey })
  } catch (e) {
    log.error('identity', 'rotation failed', e)
    res.status(500).json({ error: 'rotation failed' })
  }
})

// GET /pods — list all pods this node belongs to
router.get('/', (req, res) => {
  const pods = db.prepare(`
    SELECT p.pod_id, p.name, p.my_role, p.host_node_id, p.created_ts,
           COUNT(pm.node_id) as member_count
    FROM pods p
    LEFT JOIN pod_members pm ON pm.pod_id = p.pod_id AND pm.revoked_ts IS NULL
    GROUP BY p.pod_id ORDER BY p.created_ts DESC
  `).all()
  res.json(pods)
})

// POST /pods — create a new pod (this node becomes host)
router.post('/', async (req, res) => {
  const { name, folder_paths } = req.body
  if (!name?.trim()) return res.status(400).json({ error: 'name required' })

  await cryptoModule.init()
  const podKp = cryptoModule.generatePodKeypair()
  const pod_id = crypto.randomUUID()
  const node = db.prepare('SELECT node_id FROM nodes LIMIT 1').get()
  if (!node) return res.status(500).json({ error: 'no node identity' })

  db.prepare(`
    INSERT INTO pods (pod_id, name, my_role, my_keypair_enc, host_node_id, created_ts)
    VALUES (?, ?, 'host', ?, NULL, ?)
  `).run(pod_id, name.trim(), JSON.stringify(podKp), Date.now())

  if (Array.isArray(folder_paths)) {
    for (const fp of folder_paths) {
      db.prepare('INSERT OR IGNORE INTO pod_scopes (pod_id, folder_path) VALUES (?, ?)').run(pod_id, fp)
    }
  }

  res.status(201).json({ pod_id, name: name.trim(), pubkey: podKp.pubkey })
})

// GET /pods/:id — pod detail
router.get('/:id', (req, res) => {
  const pod = db.prepare('SELECT * FROM pods WHERE pod_id = ?').get(req.params.id)
  if (!pod) return res.status(404).json({ error: 'not found' })
  const members = db.prepare(`
    SELECT pm.node_id, pm.display_name, pm.cert_pin, pm.visibility, pm.joined_ts, pm.revoked_ts,
           p.last_seen_ts, p.last_ip
    FROM pod_members pm
    LEFT JOIN peers p ON p.node_id = pm.node_id
    WHERE pm.pod_id = ?
  `).all(req.params.id)
  const scopes = db.prepare('SELECT folder_path FROM pod_scopes WHERE pod_id = ?').all(req.params.id).map(r => r.folder_path)
  const { my_keypair_enc, ...safePod } = pod
  res.json({ ...safePod, members, scopes })
})

// POST /pods/:id/pair/open — host opens a pairing session, returns QR payload
router.post('/:id/pair/open', async (req, res) => {
  const pod = db.prepare('SELECT * FROM pods WHERE pod_id = ? AND my_role = ?').get(req.params.id, 'host')
  if (!pod) return res.status(404).json({ error: 'not found or not host' })

  await cryptoModule.init()
  const { nonce, exp } = cryptoModule.generateNonce()
  const node = db.prepare('SELECT * FROM nodes LIMIT 1').get()
  const kp = JSON.parse(pod.my_keypair_enc)

  // Build QR payload and sign it
  const payload = {
    pod_id: pod.pod_id,
    pod_pubkey: kp.pubkey,
    host_node_id: node.node_id,
    host_cert: node.cert,
    host_ip: getLanIp(),
    host_port: 7432,
    nonce,
    nonce_exp: exp
  }
  payload.sig = cryptoModule.sign(Buffer.from(JSON.stringify({ ...payload })), kp.privkey)

  res.json({ qr_payload: JSON.stringify(payload), nonce_exp: exp })
})

// POST /pods/:id/pair/complete — guest sends its identity, host verifies and pairs
router.post('/:id/pair/complete', async (req, res) => {
  const { guest_node_id, guest_pubkey, guest_cert, nonce, display_name } = req.body
  if (!guest_node_id || !guest_pubkey || !nonce) return res.status(400).json({ error: 'missing fields' })

  const pod = db.prepare('SELECT * FROM pods WHERE pod_id = ? AND my_role = ?').get(req.params.id, 'host')
  if (!pod) return res.status(404).json({ error: 'not found' })

  await cryptoModule.init()
  const valid = cryptoModule.consumeNonce(nonce)
  if (!valid) return res.status(401).json({ error: 'invalid or expired nonce' })

  const kp = JSON.parse(pod.my_keypair_enc)
  const node = db.prepare('SELECT * FROM nodes LIMIT 1').get()
  const cert_pin = crypto.createHash('sha256').update(guest_cert || guest_pubkey).digest('hex')

  db.prepare(`
    INSERT OR REPLACE INTO pod_members (pod_id, node_id, display_name, cert_pin, visibility, joined_ts)
    VALUES (?, ?, ?, ?, 'full', ?)
  `).run(pod.pod_id, guest_node_id, display_name || 'Guest', cert_pin, Date.now())

  db.prepare('INSERT OR REPLACE INTO peers (node_id, last_seen_ts) VALUES (?, ?)').run(guest_node_id, Date.now())
  db.prepare('INSERT OR IGNORE INTO peer_pods (node_id, pod_id) VALUES (?, ?)').run(guest_node_id, pod.pod_id)

  // Return pod keypair encrypted — for now plaintext (Phase 6 adds E2E encryption)
  res.json({
    pod_keypair: kp,
    host_cert: node.cert,
    host_node_id: node.node_id,
    pod_id: pod.pod_id,
    pod_name: pod.name,
  })
})

// GET /pods/:id/manifest — signed track manifest for pod peers
router.get('/:id/manifest', (req, res) => {
  const pod = db.prepare('SELECT * FROM pods WHERE pod_id = ?').get(req.params.id)
  if (!pod) return res.status(404).json({ error: 'not found' })

  const kp = JSON.parse(pod.my_keypair_enc)
  const node = db.prepare('SELECT node_id FROM nodes LIMIT 1').get()

  const scopes = db.prepare('SELECT folder_path FROM pod_scopes WHERE pod_id = ?')
    .all(req.params.id).map(r => r.folder_path)

  const allTracks = db.prepare(
    'SELECT id, path, title, artist, album, year, genre, duration, format, art_hash, replay_gain FROM tracks'
  ).all()

  const filtered = (scopes.length > 0
    ? allTracks.filter(t => scopes.some(s => t.path && t.path.startsWith(s)))
    : allTracks
  ).map(({ path, ...rest }) => rest)

  const manifest = {
    pod_id: pod.pod_id,
    node_id: node.node_id,
    stream_base: `http://${getLanIp()}:7432`,
    tracks: filtered,
    ts: Date.now(),
  }
  manifest.sig = cryptoModule.sign(Buffer.from(JSON.stringify({ ...manifest })), kp.privkey)

  res.json(manifest)
})

// GET /pods/:id/members — with last_seen_ts from peers table
router.get('/:id/members', (req, res) => {
  const pod = db.prepare('SELECT pod_id FROM pods WHERE pod_id = ?').get(req.params.id)
  if (!pod) return res.status(404).json({ error: 'not found' })
  const members = db.prepare(`
    SELECT pm.node_id, pm.display_name, pm.cert_pin, pm.visibility, pm.joined_ts, pm.revoked_ts,
           p.last_seen_ts, p.last_ip
    FROM pod_members pm
    LEFT JOIN peers p ON p.node_id = pm.node_id
    WHERE pm.pod_id = ?
  `).all(req.params.id)
  res.json(members)
})

// PATCH /pods/:id/members/:node_id — update visibility
router.patch('/:id/members/:node_id', (req, res) => {
  const { visibility, display_name } = req.body
  const VALID = new Set(['full', 'folders', 'hidden'])
  if (visibility && !VALID.has(visibility)) return res.status(400).json({ error: 'invalid visibility' })

  if (visibility) db.prepare('UPDATE pod_members SET visibility = ? WHERE pod_id = ? AND node_id = ?').run(visibility, req.params.id, req.params.node_id)
  if (display_name) db.prepare('UPDATE pod_members SET display_name = ? WHERE pod_id = ? AND node_id = ?').run(display_name.trim(), req.params.id, req.params.node_id)
  res.json({ ok: true })
})

// DELETE /pods/:id/members/:node_id — revoke + rotate pod key
router.delete('/:id/members/:node_id', async (req, res) => {
  const pod = db.prepare('SELECT * FROM pods WHERE pod_id = ? AND my_role = ?').get(req.params.id, 'host')
  if (!pod) return res.status(404).json({ error: 'not found or not host' })

  // Revoke the member
  db.prepare('UPDATE pod_members SET revoked_ts = ? WHERE pod_id = ? AND node_id = ?').run(Date.now(), req.params.id, req.params.node_id)

  // Rotate pod keypair — revoked member's old keypair is now useless
  await cryptoModule.init()
  const newKp = cryptoModule.generatePodKeypair()
  db.prepare('UPDATE pods SET my_keypair_enc = ? WHERE pod_id = ?').run(JSON.stringify(newKp), req.params.id)

  res.json({ ok: true, new_pubkey: newKp.pubkey })
})

// PATCH /pods/:id — rename pod (host only)
router.patch('/:id', (req, res) => {
  const { name } = req.body
  if (!name?.trim()) return res.status(400).json({ error: 'name required' })
  const pod = db.prepare('SELECT pod_id FROM pods WHERE pod_id = ? AND my_role = ?').get(req.params.id, 'host')
  if (!pod) return res.status(404).json({ error: 'not found or not host' })
  db.prepare('UPDATE pods SET name = ? WHERE pod_id = ?').run(name.trim(), req.params.id)
  res.json({ ok: true })
})

// DELETE /pods/:id — leave or disband a pod
router.delete('/:id', (req, res) => {
  const pod = db.prepare('SELECT pod_id, my_role FROM pods WHERE pod_id = ?').get(req.params.id)
  if (!pod) return res.status(404).json({ error: 'not found' })
  db.prepare('DELETE FROM pod_members WHERE pod_id = ?').run(req.params.id)
  db.prepare('DELETE FROM pod_scopes WHERE pod_id = ?').run(req.params.id)
  db.prepare('DELETE FROM peer_pods WHERE pod_id = ?').run(req.params.id)
  db.prepare('DELETE FROM pods WHERE pod_id = ?').run(req.params.id)
  res.json({ ok: true })
})

// GET /pods/:id/activity — recent plays attributed to this pod's members
router.get('/:id/activity', (req, res) => {
  const pod = db.prepare('SELECT pod_id FROM pods WHERE pod_id = ?').get(req.params.id)
  if (!pod) return res.status(404).json({ error: 'not found' })
  const limit = Math.min(parseInt(req.query.limit) || 50, 200)
  const rows = db.prepare(`
    SELECT ph.played_ts, ph.source_node_id,
           t.id AS track_id, t.title, t.artist, t.album, t.art_hash,
           COALESCE(pm.display_name, 'You') AS member_name
    FROM play_history ph
    JOIN tracks t ON t.id = ph.track_id
    LEFT JOIN pod_members pm ON pm.pod_id = ? AND pm.node_id = ph.source_node_id
    ORDER BY ph.played_ts DESC LIMIT ?
  `).all(req.params.id, limit)
  res.json(rows)
})

// POST /pods/join — guest daemon registers pod membership received from pairing
router.post('/join', (req, res) => {
  const { pod_id, pod_name, pod_keypair, host_node_id, host_ip, host_port } = req.body
  if (!pod_id || !pod_name || !pod_keypair || !host_node_id) {
    return res.status(400).json({ error: 'missing fields' })
  }

  db.prepare(`
    INSERT OR REPLACE INTO pods (pod_id, name, my_role, my_keypair_enc, host_node_id, created_ts)
    VALUES (?, ?, 'member', ?, ?, COALESCE((SELECT created_ts FROM pods WHERE pod_id = ?), ?))
  `).run(pod_id, pod_name, JSON.stringify(pod_keypair), host_node_id, pod_id, Date.now())

  if (host_ip) {
    db.prepare('INSERT OR REPLACE INTO peers (node_id, last_ip, last_port, last_seen_ts) VALUES (?, ?, ?, ?)')
      .run(host_node_id, host_ip, host_port || 7432, Date.now())
    db.prepare('INSERT OR IGNORE INTO peer_pods (node_id, pod_id) VALUES (?, ?)').run(host_node_id, pod_id)
  }

  res.json({ ok: true })
})

module.exports = router
