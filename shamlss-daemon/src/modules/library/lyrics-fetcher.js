'use strict'
const https = require('https')
const http = require('http')
const log = require('../../core/log')

const CACHE_TTL_MS = 30 * 24 * 60 * 60 * 1000  // 30 days

// ── HTTP helper ───────────────────────────────────────────────────────────────

function _get(url, timeoutMs = 8000) {
  return new Promise((resolve, reject) => {
    const mod = url.startsWith('https') ? https : http
    const req = mod.get(url, {
      headers: {
        'User-Agent': 'Shamlss/1.0 (self-hosted music player; +https://github.com/the711Conspiracy/shameless)',
        'Accept': 'application/json, text/html',
      }
    }, (res) => {
      if (res.statusCode === 301 || res.statusCode === 302) {
        const loc = res.headers.location
        if (loc) return _get(loc, timeoutMs).then(resolve).catch(reject)
        return reject(new Error(`redirect with no Location`))
      }
      if (res.statusCode !== 200) { res.destroy(); return reject(new Error(`HTTP ${res.statusCode}`)) }
      let body = ''
      res.on('data', d => { body += d; if (body.length > 500_000) { res.destroy(); reject(new Error('response too large')) } })
      res.on('end', () => resolve(body))
      res.on('error', reject)
    })
    req.on('error', reject)
    req.setTimeout(timeoutMs, () => { req.destroy(); reject(new Error('timeout')) })
  })
}

function _slug(s) {
  return (s || '').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '')
}

function _encode(s) {
  return encodeURIComponent(s || '')
}

// ── Provider 1: LRCLIB (free, no key, synced + plain) ────────────────────────
// https://lrclib.net/api

async function _lrclib(title, artist, album, durationSec) {
  try {
    let url = `https://lrclib.net/api/get?track_name=${_encode(title)}&artist_name=${_encode(artist)}`
    if (album) url += `&album_name=${_encode(album)}`
    if (durationSec > 0) url += `&duration=${Math.round(durationSec)}`

    const body = await _get(url)
    const data = JSON.parse(body)
    if (data.instrumental) return null  // instrumental — no lyrics to show
    const plain = data.plainLyrics?.trim() || null
    const sync = data.syncedLyrics?.trim() || null
    if (!plain && !sync) return null
    return { plain, sync, source: 'lrclib' }
  } catch (e) {
    log.debug('lyrics', `lrclib miss: ${e.message}`)
    return null
  }
}

// ── Provider 2: lyrics.ovh (free, no key, plain only) ────────────────────────

async function _lyricsOvh(title, artist) {
  try {
    const url = `https://api.lyrics.ovh/v1/${_encode(artist)}/${_encode(title)}`
    const body = await _get(url)
    const data = JSON.parse(body)
    const plain = data.lyrics?.trim()
    if (!plain || data.error) return null
    return { plain, sync: null, source: 'lyrics.ovh' }
  } catch (e) {
    log.debug('lyrics', `lyrics.ovh miss: ${e.message}`)
    return null
  }
}

// ── Provider 3: Genius page scrape (no key, plain only) ──────────────────────
// Searches Genius and scrapes the lyrics page

async function _genius(title, artist) {
  try {
    // Step 1: search Genius
    const q = _encode(`${artist} ${title}`)
    const searchBody = await _get(`https://genius.com/api/search/multi?q=${q}`)
    const results = JSON.parse(searchBody)
    const hit = results?.response?.sections
      ?.find(s => s.type === 'song')
      ?.hits?.[0]?.result
    if (!hit?.url) return null

    // Step 2: scrape the lyrics page
    const page = await _get(hit.url, 12000)
    // Genius embeds lyrics in <div data-lyrics-container="true"> elements
    const containers = [...page.matchAll(/data-lyrics-container="true"[^>]*>([\s\S]*?)<\/div>/g)]
    if (!containers.length) return null

    const plain = containers
      .map(m => m[1]
        .replace(/<br\s*\/?>/gi, '\n')
        .replace(/<[^>]+>/g, '')
        .replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'")
      )
      .join('\n')
      .trim()

    if (!plain) return null
    return { plain, sync: null, source: 'genius' }
  } catch (e) {
    log.debug('lyrics', `genius miss: ${e.message}`)
    return null
  }
}

// ── Provider 4: AZLyrics scrape (no key, plain only) ─────────────────────────

async function _azlyrics(title, artist) {
  try {
    const a = artist.toLowerCase().replace(/^the\s+/, '').replace(/[^a-z0-9]/g, '')
    const t = title.toLowerCase().replace(/[^a-z0-9]/g, '')
    const url = `https://www.azlyrics.com/lyrics/${a}/${t}.html`
    const page = await _get(url, 12000)

    // AZLyrics puts lyrics between two specific HTML comments
    const START = '<!-- Usage of azlyrics.com content by any third-party lyrics provider is prohibited'
    const END = '<div'
    const si = page.indexOf(START)
    if (si === -1) return null
    const block = page.slice(si)
    const close = block.indexOf('</div>')
    if (close === -1) return null
    const inner = block.slice(block.indexOf('>') + 1, close)

    const plain = inner
      .replace(/<br\s*\/?>/gi, '\n')
      .replace(/<[^>]+>/g, '')
      .replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'")
      .trim()

    if (!plain || plain.length < 20) return null
    return { plain, sync: null, source: 'azlyrics' }
  } catch (e) {
    log.debug('lyrics', `azlyrics miss: ${e.message}`)
    return null
  }
}

// ── Public API ────────────────────────────────────────────────────────────────

const PROVIDERS = [_lrclib, _lyricsOvh, _genius, _azlyrics]

// Fetch lyrics for a track, trying providers in priority order.
// Returns { plain, sync, source } or null if all providers miss.
async function fetchLyrics({ title, artist, album, duration }) {
  const durationSec = duration ? duration / 1000 : 0
  for (const provider of PROVIDERS) {
    const args = provider === _lrclib
      ? [title, artist, album, durationSec]
      : [title, artist]
    const result = await provider(...args)
    if (result) {
      log.info('lyrics', `found via ${result.source}: "${title}" – ${artist}`)
      return result
    }
  }
  log.debug('lyrics', `no lyrics found: "${title}" – ${artist}`)
  return null
}

// Cache helpers (called from routes.js with the db instance)
function getCached(db, trackId) {
  const row = db.prepare('SELECT plain_lyrics, sync_lyrics, source, fetched_ts FROM lyrics_cache WHERE track_id = ?').get(trackId)
  if (!row) return null
  if (Date.now() - row.fetched_ts > CACHE_TTL_MS) return null  // stale
  return { plain: row.plain_lyrics, sync: row.sync_lyrics, source: row.source }
}

function setCached(db, trackId, result) {
  db.prepare(`
    INSERT OR REPLACE INTO lyrics_cache (track_id, plain_lyrics, sync_lyrics, source, fetched_ts)
    VALUES (?, ?, ?, ?, ?)
  `).run(trackId, result.plain || null, result.sync || null, result.source, Date.now())
}

function clearCache(db, trackId) {
  db.prepare('DELETE FROM lyrics_cache WHERE track_id = ?').run(trackId)
}

module.exports = { fetchLyrics, getCached, setCached, clearCache }
