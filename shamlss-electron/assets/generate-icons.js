#!/usr/bin/env node
// Generates tray icons and app icon from scratch — no external deps.
const zlib = require('zlib')
const fs = require('fs')
const path = require('path')

function makePNG(size, r, g, b) {
  const sig = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10])
  const ihdr = Buffer.alloc(13)
  ihdr.writeUInt32BE(size, 0); ihdr.writeUInt32BE(size, 4)
  ihdr[8] = 8; ihdr[9] = 2

  function chunk(type, data) {
    const len = Buffer.alloc(4); len.writeUInt32BE(data.length)
    const typeB = Buffer.from(type)
    const crcBuf = Buffer.concat([typeB, data])
    let crc = 0xffffffff
    for (const b of crcBuf) { crc ^= b; for (let i = 0; i < 8; i++) crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0) }
    crc = (~crc) >>> 0
    const crcB = Buffer.alloc(4); crcB.writeUInt32BE(crc)
    return Buffer.concat([len, typeB, data, crcB])
  }

  const rowSize = size * 3
  const raw = Buffer.alloc((rowSize + 1) * size)
  for (let y = 0; y < size; y++) {
    raw[y * (rowSize + 1)] = 0
    for (let x = 0; x < size; x++) {
      const off = y * (rowSize + 1) + 1 + x * 3
      raw[off] = r; raw[off + 1] = g; raw[off + 2] = b
    }
  }
  return Buffer.concat([sig, chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(raw)), chunk('IEND', Buffer.alloc(0))])
}

function makeICO(sizes, r, g, b) {
  const images = sizes.map(s => makePNG(s, r, g, b))
  const count = sizes.length
  const header = Buffer.alloc(6)
  header.writeUInt16LE(0, 0); header.writeUInt16LE(1, 2); header.writeUInt16LE(count, 4)
  const entries = []
  let offset = 6 + count * 16
  for (let i = 0; i < count; i++) {
    const e = Buffer.alloc(16)
    const s = sizes[i]
    e[0] = s === 256 ? 0 : s; e[1] = s === 256 ? 0 : s
    e[2] = 0; e[3] = 0
    e.writeUInt16LE(1, 4); e.writeUInt16LE(32, 6)
    e.writeUInt32LE(images[i].length, 8); e.writeUInt32LE(offset, 12)
    offset += images[i].length
    entries.push(e)
  }
  return Buffer.concat([header, ...entries, ...images])
}

const assetsDir = path.join(__dirname)
const buildDir = path.join(__dirname, '..', 'build')
if (!fs.existsSync(buildDir)) fs.mkdirSync(buildDir, { recursive: true })

// Amber #E8A020 = rgb(232, 160, 32)
const R = 232, G = 160, B = 32

fs.writeFileSync(path.join(assetsDir, 'tray-16.png'), makePNG(16, R, G, B))
fs.writeFileSync(path.join(assetsDir, 'tray-32.png'), makePNG(32, R, G, B))
fs.writeFileSync(path.join(buildDir, 'icon.ico'), makeICO([16, 32, 48, 256], R, G, B))

console.log('shamlss: icons generated')
