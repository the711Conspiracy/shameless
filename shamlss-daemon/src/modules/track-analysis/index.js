'use strict'
const { spawn } = require('child_process')
const mm = require('music-metadata')
const db = require('../../core/db')
const log = require('../../core/log')
const events = require('../events')

// ── BPM estimator ───────────────────────────────────────────────────────────
// Low-pass IIR → energy envelope → autocorrelation → period → BPM
function estimateBpm(samples, sampleRate) {
  if (!samples || samples.length < sampleRate * 5) return null  // need ≥5s

  // Low-pass ~200 Hz to isolate kick/bass transients
  const alpha = Math.exp(-2 * Math.PI * 200 / sampleRate)
  const flt = new Float32Array(samples.length)
  let prev = 0
  for (let i = 0; i < samples.length; i++) {
    prev = alpha * prev + (1 - alpha) * samples[i]
    flt[i] = prev
  }

  // RMS energy in 10 ms windows
  const hop = Math.floor(sampleRate * 0.01)
  const nFrames = Math.floor(flt.length / hop)
  const energy = new Float32Array(nFrames)
  for (let i = 0; i < nFrames; i++) {
    let sum = 0
    const s = i * hop
    for (let j = 0; j < hop; j++) sum += flt[s + j] ** 2
    energy[i] = Math.sqrt(sum / hop)
  }

  // Autocorrelation — search 60–200 BPM
  const hopSec = 0.01
  const minLag = Math.floor(60 / 200 / hopSec)
  const maxLag = Math.ceil(60 / 60 / hopSec)
  let best = -Infinity, bestLag = minLag
  for (let lag = minLag; lag <= maxLag && lag < energy.length; lag++) {
    let sum = 0
    const n = energy.length - lag
    for (let i = 0; i < n; i++) sum += energy[i] * energy[i + lag]
    const corr = sum / n
    if (corr > best) { best = corr; bestLag = lag }
  }

  const bpm = Math.round(60 / (bestLag * hopSec))
  return bpm >= 60 && bpm <= 200 ? bpm : null
}

// ── PCM decoder (ffmpeg) ─────────────────────────────────────────────────────
function decodePcm(filePath) {
  return new Promise((resolve) => {
    const proc = spawn('ffmpeg', [
      '-i', filePath,
      '-f', 'f32le', '-ar', '22050', '-ac', '1',
      '-t', '90',       // analyse first 90s — enough for BPM
      'pipe:1'
    ], { stdio: ['ignore', 'pipe', 'ignore'] })

    const chunks = []
    proc.stdout.on('data', (c) => chunks.push(c))
    proc.stdout.on('end', () => {
      if (!chunks.length) { resolve(null); return }
      const buf = Buffer.concat(chunks)
      const ab = new ArrayBuffer(buf.byteLength)
      new Uint8Array(ab).set(buf)
      resolve(new Float32Array(ab))
    })
    proc.on('error', () => resolve(null))
    // Safety timeout
    const t = setTimeout(() => { try { proc.kill('SIGKILL') } catch (_) {}; resolve(null) }, 45000)
    proc.on('close', () => clearTimeout(t))
  })
}

// ── Waveform builder ─────────────────────────────────────────────────────────
// Returns 300-element normalized RMS array (values 0–1)
function computeWaveform(samples, numBars = 300) {
  const segLen = Math.floor(samples.length / numBars)
  if (segLen < 1) return null
  const bars = new Array(numBars)
  let maxVal = 0
  for (let i = 0; i < numBars; i++) {
    let sum = 0
    const start = i * segLen
    for (let j = 0; j < segLen; j++) sum += samples[start + j] ** 2
    bars[i] = Math.sqrt(sum / segLen)
    if (bars[i] > maxVal) maxVal = bars[i]
  }
  if (maxVal > 0) for (let i = 0; i < numBars; i++) bars[i] /= maxVal
  return bars
}

// ── Queue state ──────────────────────────────────────────────────────────────
const _queue = []
let _active = false
const _status = { done: 0, errors: 0, current: null, startedAt: null }
let _ffmpegAvailable = null   // null=unknown, true/false after first attempt

function getStatus() {
  const total = db.prepare('SELECT COUNT(*) AS n FROM tracks').get().n
  const analyzed = db.prepare('SELECT COUNT(*) AS n FROM track_analysis WHERE analyzed_ts IS NOT NULL').get().n
  return {
    pending: _queue.length,
    active: _active,
    done: _status.done,
    errors: _status.errors,
    current: _status.current,
    total,
    analyzed,
    ffmpeg: _ffmpegAvailable,
  }
}

function enqueue(trackIds) {
  let added = 0
  for (const id of trackIds) {
    if (!_queue.includes(id)) { _queue.push(id); added++ }
  }
  if (added) log.info('analysis', `queued ${added} tracks (${_queue.length} pending)`)
  if (!_active) _runNext()
  return added
}

function queueAll() {
  const rows = db.prepare(`
    SELECT t.id FROM tracks t
    LEFT JOIN track_analysis ta ON ta.track_id = t.id
    WHERE ta.track_id IS NULL OR ta.analyzed_ts IS NULL
  `).all()
  if (!rows.length) { log.info('analysis', 'all tracks already analyzed'); return 0 }
  _status.done = 0; _status.errors = 0; _status.startedAt = Date.now()
  return enqueue(rows.map(r => r.id))
}

async function _runNext() {
  if (!_queue.length) {
    _active = false; _status.current = null
    if (_status.startedAt) {
      log.info('analysis', `complete — ${_status.done} ok, ${_status.errors} errors`)
      events.emit('analysis.complete', { done: _status.done, errors: _status.errors })
      _status.startedAt = null
    }
    return
  }
  _active = true
  const id = _queue.shift()
  _status.current = id
  try {
    await _analyzeTrack(id)
    _status.done++
  } catch (e) {
    _status.errors++
    log.warn('analysis', `failed for ${id}`, e)
  }
  setImmediate(_runNext)
}

async function _analyzeTrack(trackId) {
  const track = db.prepare('SELECT id, path, title FROM tracks WHERE id = ?').get(trackId)
  if (!track) return

  // 1. Extract from embedded tags (fast, no deps)
  const meta = await mm.parseFile(track.path, { skipCovers: true, duration: false })
  let bpm = meta.common.bpm ? Math.round(meta.common.bpm) : null
  const key = meta.common.key || null
  const loudness = meta.format.loudness ?? null

  // 2. Deep BPM + waveform via ffmpeg if tag absent or PCM not yet decoded
  let waveform = null
  if (!bpm) {
    try {
      const pcm = await decodePcm(track.path)
      if (pcm) {
        _ffmpegAvailable = true
        bpm = estimateBpm(pcm, 22050)
        waveform = computeWaveform(pcm)
      } else if (_ffmpegAvailable === null) {
        _ffmpegAvailable = false
        log.info('analysis', 'ffmpeg not available — BPM and waveform require ffmpeg install')
      }
    } catch (e) {
      log.debug('analysis', `deep analysis error: ${track.path}`, e)
    }
  } else {
    // BPM from tag — still decode for waveform if ffmpeg available
    try {
      const pcm = await decodePcm(track.path)
      if (pcm) {
        _ffmpegAvailable = true
        waveform = computeWaveform(pcm)
      }
    } catch (e) {
      log.debug('analysis', `waveform decode error: ${track.path}`, e)
    }
  }

  db.prepare(`
    INSERT OR REPLACE INTO track_analysis (track_id, bpm, musical_key, loudness, waveform, analyzed_ts)
    VALUES (?, ?, ?, ?, ?, ?)
  `).run(trackId, bpm, key, loudness, waveform ? JSON.stringify(waveform) : null, Date.now())

  log.debug('analysis', `${track.title || trackId} -> bpm=${bpm ?? '?'} key=${key ?? '?'} waveform=${waveform ? 'yes' : 'no'}`)
  events.emit('analysis.track.done', { track_id: trackId, bpm, key })
}

module.exports = { getStatus, enqueue, queueAll }
