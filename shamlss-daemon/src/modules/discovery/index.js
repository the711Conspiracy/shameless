'use strict'
const dgram = require('dgram')
const os = require('os')
const db = require('../../core/db')
const log = require('../../core/log')
const events = require('../events')

const DISCOVERY_PORT = 7433
const BROADCAST_INTERVAL_MS = 5000

let _socket = null
let _timer = null
let _nodeId = null
let _nodeName = null

function getLanIp() {
  for (const ifaces of Object.values(os.networkInterfaces())) {
    for (const iface of ifaces) {
      if (iface.family === 'IPv4' && !iface.internal) return iface.address
    }
  }
  return '127.0.0.1'
}

function getBroadcastAddr(ip) {
  const parts = ip.split('.')
  parts[3] = '255'
  return parts.join('.')
}

function start(nodeId, nodeName) {
  _nodeId = nodeId
  _nodeName = nodeName

  _socket = dgram.createSocket({ type: 'udp4', reuseAddr: true })

  _socket.on('error', (e) => {
    if (e.code !== 'EADDRINUSE') log.warn('discovery', 'socket error', e)
    else log.warn('discovery', `UDP port ${DISCOVERY_PORT} already in use — discovery disabled`)
  })

  _socket.on('message', (msg, rinfo) => {
    try {
      const data = JSON.parse(msg.toString('utf8'))
      if (!data.node_id || data.node_id === _nodeId) return

      const now = Date.now()
      const existing = db.prepare('SELECT node_id FROM peers WHERE node_id = ?').get(data.node_id)

      db.prepare(`
        INSERT OR REPLACE INTO peers (node_id, last_ip, last_port, last_seen_ts)
        VALUES (?, ?, ?, ?)
      `).run(data.node_id, rinfo.address, data.port || 7432, now)

      if (!existing) {
        log.info('discovery', `found: ${data.name || data.node_id} at ${rinfo.address}`)
        events.emit('peer.connected', { node_id: data.node_id, name: data.name, ip: rinfo.address, port: data.port || 7432 })
      }
    } catch (e) {
      log.debug('discovery', `bad packet from ${rinfo.address}`, e)
    }
  })

  _socket.bind(DISCOVERY_PORT, () => {
    try { _socket.setBroadcast(true) } catch (e) {
      log.warn('discovery', 'could not enable broadcast', e)
    }
    log.info('discovery', `listening on UDP :${DISCOVERY_PORT}`)
    _broadcast()
    _timer = setInterval(_broadcast, BROADCAST_INTERVAL_MS)
  })
}

function _broadcast() {
  if (!_socket || !_nodeId) return
  const ip = getLanIp()
  const payload = Buffer.from(JSON.stringify({
    node_id: _nodeId,
    name: _nodeName,
    port: 7432,
    ip,
    ts: Date.now(),
  }), 'utf8')
  const bcast = getBroadcastAddr(ip)
  _socket.send(payload, 0, payload.length, DISCOVERY_PORT, bcast, (e) => {
    if (e) log.debug('discovery', `broadcast failed to ${bcast}`, e)
  })
}

function stop() {
  if (_timer) { clearInterval(_timer); _timer = null }
  if (_socket) {
    try { _socket.close() } catch (_) {}
    _socket = null
  }
  log.info('discovery', 'stopped')
}

module.exports = { start, stop }
