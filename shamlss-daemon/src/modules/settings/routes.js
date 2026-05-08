const express = require('express')
const router = express.Router()
const db = require('../../core/db')
const flags = require('../feature-flags')
const log = require('../../core/log')

router.get('/', (req, res) => {
  const node = db.prepare('SELECT node_id, display_name, created_ts FROM nodes LIMIT 1').get()
  res.json({ node, flags: flags.getAll() })
})

router.patch('/node', (req, res) => {
  const { display_name } = req.body
  if (!display_name?.trim()) return res.status(400).json({ error: 'display_name required' })
  db.prepare('UPDATE nodes SET display_name = ?').run(display_name.trim())
  log.info('settings', `node display_name -> "${display_name.trim()}"`)
  res.json({ ok: true })
})

router.patch('/flags', (req, res) => {
  const updates = req.body
  if (typeof updates !== 'object') return res.status(400).json({ error: 'body must be object' })
  const current = flags.getAll()
  const merged = { ...current }
  for (const [k, v] of Object.entries(updates)) {
    if (k in current) merged[k] = !!v
  }
  const fs = require('fs')
  const path = require('path')
  const flagsPath = path.join(__dirname, '..', '..', '..', 'config', 'features.json')
  fs.writeFileSync(flagsPath, JSON.stringify(merged, null, 2))
  flags.reload()
  log.info('settings', `feature flags updated: ${JSON.stringify(updates)}`)
  res.json({ ok: true, flags: flags.getAll() })
})

module.exports = router
