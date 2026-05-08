const db = require('./db')
const cryptoModule = require('../modules/crypto')

async function bootstrap() {
  await cryptoModule.init()
  const existing = db.prepare('SELECT * FROM nodes LIMIT 1').get()
  if (existing) return existing

  const identity = cryptoModule.generateNodeIdentity()
  db.prepare(`
    INSERT INTO nodes (node_id, pubkey, cert, display_name, created_ts)
    VALUES (?, ?, ?, ?, ?)
  `).run(identity.node_id, identity.pubkey, identity.cert, 'My Node', Date.now())

  const row = db.prepare('SELECT * FROM nodes WHERE node_id = ?').get(identity.node_id)
  row._privkey = identity.privkey
  return row
}

module.exports = { bootstrap }
