'use strict'
const { app, BrowserWindow, Tray, Menu } = require('electron')
const path = require('path')
const http = require('http')
const { spawn } = require('child_process')
const WebSocket = require('ws')
const fs = require('fs')

const gotLock = app.requestSingleInstanceLock()
if (!gotLock) { app.quit(); process.exit(0) }

const daemonDir = app.isPackaged
  ? path.join(process.resourcesPath, 'shamlss-daemon')
  : path.join(__dirname, '..', 'shamlss-daemon')

const daemonScript = path.join(daemonDir, 'src', 'daemon.js')
const logDir = path.join(require('os').homedir(), '.shamlss')
const logPath = path.join(logDir, 'daemon.log')

let daemonProc = null
let tray = null
let win = null
let isQuitting = false
let nowPlaying = null
let nodeName = 'Shamlss'
let ws = null

function ensureLogDir() {
  if (!fs.existsSync(logDir)) fs.mkdirSync(logDir, { recursive: true })
}

function findNode() {
  const bundled = path.join(
    app.isPackaged ? process.resourcesPath : path.join(__dirname, 'resources'),
    'node',
    process.platform === 'win32' ? 'node.exe' : 'node'
  )
  if (fs.existsSync(bundled)) return bundled
  return 'node' // fall back to system node in dev
}

function startDaemon() {
  ensureLogDir()
  const logFd = fs.openSync(logPath, 'a')
  const nodeExe = findNode()

  daemonProc = spawn(nodeExe, [daemonScript], {
    cwd: daemonDir,
    env: { ...process.env },
    stdio: ['ignore', logFd, logFd],
    detached: false
  })

  daemonProc.on('error', (e) => {
    fs.appendFileSync(logPath, `[electron] daemon spawn error: ${e.message}\n`)
  })
  daemonProc.on('exit', (code, sig) => {
    fs.appendFileSync(logPath, `[electron] daemon exited code=${code} sig=${sig}\n`)
    if (!isQuitting) {
      setTimeout(startDaemon, 3000) // restart on crash
    }
  })
}

function stopDaemon() {
  if (daemonProc) {
    daemonProc.removeAllListeners('exit')
    daemonProc.kill('SIGTERM')
    daemonProc = null
  }
}

function waitForDaemon(maxMs = 15000) {
  return new Promise((resolve) => {
    const deadline = Date.now() + maxMs
    const check = () => {
      http.get('http://127.0.0.1:7432/ping', (res) => {
        let body = ''
        res.on('data', d => body += d)
        res.on('end', () => {
          try { nodeName = JSON.parse(body).name || 'Shamlss' } catch {}
          resolve(true)
        })
      }).on('error', () => {
        if (Date.now() < deadline) setTimeout(check, 500)
        else resolve(false)
      })
    }
    check()
  })
}

function buildTrayMenu() {
  const items = [
    { label: 'Open Shamlss', click: () => { win.show(); win.focus() } },
    { type: 'separator' }
  ]
  if (nowPlaying) {
    items.push({ label: `♪  ${nowPlaying}`, enabled: false })
    items.push({ type: 'separator' })
  }
  items.push({
    label: 'Quit',
    click: () => {
      isQuitting = true
      if (ws) ws.close()
      stopDaemon()
      app.quit()
    }
  })
  tray.setContextMenu(Menu.buildFromTemplate(items))
}

function updateTooltip() {
  const base = `${nodeName}  ·  :7432`
  tray.setToolTip(nowPlaying ? `${base}\n♪  ${nowPlaying}` : base)
}

function connectWs() {
  ws = new WebSocket('ws://127.0.0.1:7432')
  ws.on('message', (data) => {
    try {
      const msg = JSON.parse(data.toString())
      if (msg.type === 'now_playing') {
        const { title, artist } = msg.payload || {}
        nowPlaying = artist ? `${artist} — ${title}` : title
        updateTooltip()
        buildTrayMenu()
      }
    } catch {}
  })
  ws.on('close', () => {
    ws = null
    if (!isQuitting) setTimeout(connectWs, 5000)
  })
  ws.on('error', () => {})
}

function createWindow() {
  win = new BrowserWindow({
    width: 1200,
    height: 800,
    show: false,
    backgroundColor: '#0a0f1e',
    title: 'Shamlss',
    webPreferences: { nodeIntegration: false, contextIsolation: true }
  })
  win.loadURL('http://127.0.0.1:7432/ui')
  win.once('ready-to-show', () => win.show())
  win.on('close', (e) => {
    if (!isQuitting) { e.preventDefault(); win.hide() }
  })
}

function createTray() {
  const iconPath = path.join(__dirname, 'assets', 'tray-16.png')
  tray = new Tray(iconPath)
  updateTooltip()
  buildTrayMenu()
  tray.on('click', () => { win.show(); win.focus() })
}

app.on('second-instance', () => { if (win) { win.show(); win.focus() } })
app.on('window-all-closed', () => {})
app.on('before-quit', () => { isQuitting = true; stopDaemon() })

app.whenReady().then(async () => {
  startDaemon()
  createTray()
  const ready = await waitForDaemon()
  createWindow()
  updateTooltip()
  if (ready) connectWs()
  else fs.appendFileSync(logPath, '[electron] WARNING: daemon did not respond within 15s\n')
})
