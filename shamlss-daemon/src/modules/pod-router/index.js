const db = require('../../core/db')
const cryptoModule = require('../crypto')
const flags = require('../feature-flags')
const log = require('../../core/log')

// Routes that are always open — no pod auth required
const PUBLIC = new Set(['/ping'])
const PUBLIC_PREFIX = ['/pods/'] // pod management itself is open (auth happens at pairing)

function isPodAuthRequired(path) {
  if (PUBLIC.has(path)) return false
  for (const p of PUBLIC_PREFIX) if (path.startsWith(p)) return false
  return true
}

async function podRouter(req, res, next) {
  if (!flags.is('p2_pairing')) return next()

  const podId = req.headers['pod-id']
  const nodeId = req.headers['node-id']
  const authToken = req.headers['authorization']
  const tsHeader = req.headers['timestamp']

  // No pod headers = local/unauthenticated client — pass through without a pod context
  if (!podId) return next()

  try {
    await cryptoModule.init()

    const ts = parseInt(tsHeader, 10)
    if (isNaN(ts) || Math.abs(Date.now() - ts) > 30000) {
      log.warn('pod-router', `timestamp out of window for node ${nodeId} on ${req.path}`)
      return res.status(401).end()
    }

    const pod = db.prepare('SELECT * FROM pods WHERE pod_id = ?').get(podId)
    if (!pod) {
      log.warn('pod-router', `unknown pod ${podId} from node ${nodeId}`)
      return res.status(401).end()
    }

    const member = db.prepare('SELECT * FROM pod_members WHERE pod_id = ? AND node_id = ? AND revoked_ts IS NULL').get(podId, nodeId)
    if (!member) {
      log.warn('pod-router', `node ${nodeId} not a member of pod ${podId} or revoked`)
      return res.status(401).end()
    }

    const valid = cryptoModule.verify(
      JSON.stringify({ pod_id: podId, node_id: nodeId, ts }),
      authToken,
      member.cert_pin
    )
    if (!valid) {
      log.warn('pod-router', `signature invalid for node ${nodeId} on pod ${podId}`)
      return res.status(401).end()
    }

    req.podContext = {
      pod_id: podId,
      node_id: nodeId,
      visibility: member.visibility,
      cert_pin: member.cert_pin
    }

    next()
  } catch (e) {
    log.error('pod-router', `auth error on ${req.path}`, e)
    res.status(401).end()
  }
}

module.exports = { podRouter }
