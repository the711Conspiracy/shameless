'use strict'
const fs = require('fs')
const path = require('path')
const os = require('os')

const LOG_PATH = path.join(os.homedir(), '.shamlss', 'daemon.log')
const OLD_PATH  = LOG_PATH + '.old'
const RING_SIZE = 500
const MAX_BYTES = 5 * 1024 * 1024

const _ring = []
let _fd = null

function _open() {
  try {
    const dir = path.dirname(LOG_PATH)
    if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true })
    if (fs.existsSync(LOG_PATH) && fs.statSync(LOG_PATH).size > MAX_BYTES) {
      if (fs.existsSync(OLD_PATH)) fs.unlinkSync(OLD_PATH)
      fs.renameSync(LOG_PATH, OLD_PATH)
    }
    _fd = fs.openSync(LOG_PATH, 'a')
  } catch (e) {
    process.stderr.write(`[log] failed to open log file: ${e.message}\n`)
  }
}
_open()

function _write(level, mod, msg, err) {
  const ts = Date.now()
  const errMsg  = err ? (err.message || String(err)) : undefined
  const errStack = err?.stack

  const entry = { ts, level, mod, msg }
  if (errMsg) entry.err = errMsg
  _ring.push(entry)
  if (_ring.length > RING_SIZE) _ring.shift()

  const line = `${new Date(ts).toISOString()} ${level.padEnd(5)} [${mod}] ${msg}${errMsg ? ' -> ' + errMsg : ''}\n`
  process.stderr.write(Buffer.from(line, 'utf8'))

  if (_fd !== null) {
    try {
      fs.writeSync(_fd, Buffer.from(line, 'utf8'))
      if (level === 'ERROR' && errStack) {
        const trace = errStack.split('\n').slice(1, 5).join('\n') + '\n'
        fs.writeSync(_fd, Buffer.from(trace, 'utf8'))
      }
    } catch {}
  }
}

module.exports = {
  debug: (mod, msg)       => _write('DEBUG', mod, msg),
  info:  (mod, msg)       => _write('INFO',  mod, msg),
  warn:  (mod, msg, err)  => _write('WARN',  mod, msg, err),
  error: (mod, msg, err)  => _write('ERROR', mod, msg, err),
  recent: (n = 200)       => _ring.slice(-Math.min(n, RING_SIZE)),
  logPath: LOG_PATH,
}
