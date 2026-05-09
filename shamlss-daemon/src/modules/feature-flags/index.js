const fs = require('fs')
const path = require('path')

const flagsPath = path.join(__dirname, '..', '..', '..', 'config', 'features.json')

let flags = {}

function reload() {
  try {
    flags = JSON.parse(fs.readFileSync(flagsPath, 'utf8'))
  } catch (e) {
    process.stderr.write(`[feature-flags] failed to load ${flagsPath}: ${e.message}\n`)
    // Keep previously loaded flags; do not reset to empty object
  }
}

function is(name) {
  return !!flags[name]
}

class FeatureDisabledError extends Error {
  constructor(name) {
    super(`Feature disabled: ${name}`)
    this.code = 'FEATURE_DISABLED'
  }
}

function require_(name) {
  if (!is(name)) throw new FeatureDisabledError(name)
}

function getAll() {
  return { ...flags }
}

reload()

module.exports = { is, require: require_, reload, getAll, FeatureDisabledError }
