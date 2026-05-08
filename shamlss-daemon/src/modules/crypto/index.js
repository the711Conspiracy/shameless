const crypto = require('crypto')
const db = require('../../core/db')

async function init() {
  // Node.js built-in crypto — no async init needed
}

function generateNodeIdentity() {
  const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519')
  const pubDer = publicKey.export({ type: 'spki', format: 'der' })
  const node_id = crypto.createHash('sha256').update(pubDer).digest('hex')
  return {
    node_id,
    pubkey: pubDer.toString('hex'),
    privkey: privateKey.export({ type: 'pkcs8', format: 'der' }).toString('hex'),
    cert: pubDer.toString('hex')
  }
}

function generatePodKeypair() {
  const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519')
  const pubDer = publicKey.export({ type: 'spki', format: 'der' })
  return {
    pubkey: pubDer.toString('hex'),
    privkey: privateKey.export({ type: 'pkcs8', format: 'der' }).toString('hex')
  }
}

function sign(payload, privkeyHex) {
  const msg = Buffer.isBuffer(payload) ? payload : Buffer.from(JSON.stringify(payload))
  const privkey = crypto.createPrivateKey({ key: Buffer.from(privkeyHex, 'hex'), format: 'der', type: 'pkcs8' })
  return crypto.sign(null, msg, privkey).toString('hex')
}

function verify(payload, sigHex, pubkeyHex) {
  try {
    const msg = Buffer.isBuffer(payload) ? payload : Buffer.from(JSON.stringify(payload))
    const sig = Buffer.from(sigHex, 'hex')
    const pubkey = crypto.createPublicKey({ key: Buffer.from(pubkeyHex, 'hex'), format: 'der', type: 'spki' })
    return crypto.verify(null, msg, pubkey, sig)
  } catch {
    return false
  }
}

function generateNonce() {
  const nonce = crypto.randomBytes(32).toString('hex')
  const exp = Date.now() + 60000
  db.prepare('INSERT INTO nonces (nonce, exp) VALUES (?, ?)').run(nonce, exp)
  return { nonce, exp }
}

function consumeNonce(nonce) {
  db.prepare('DELETE FROM nonces WHERE exp < ?').run(Date.now())
  const row = db.prepare('SELECT nonce FROM nonces WHERE nonce = ? AND exp > ?').get(nonce, Date.now())
  if (!row) return false
  db.prepare('DELETE FROM nonces WHERE nonce = ?').run(nonce)
  return true
}

function hashFile(buffer) {
  return crypto.createHash('sha256').update(buffer).digest('hex')
}

module.exports = { init, generateNodeIdentity, generatePodKeypair, sign, verify, generateNonce, consumeNonce, hashFile }
