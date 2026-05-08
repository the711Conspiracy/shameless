# Shamlss — Beta Installation Guide

## What is Shamlss?
Shamlss is a self-hosted music streaming app. You run a small server on your PC and stream to your phone or any browser on your network. Nothing goes to the cloud.

---

## Windows (recommended for most people)

**Run `Shamlss-Desktop-Setup-Windows.exe`**

1. Double-click the installer
2. Click **Next** → choose install folder → click **Install**
3. Click **Finish** — Shamlss starts automatically

That's it. Shamlss appears in your system tray (bottom-right corner). The web player opens in the app window. Your phone can connect too — see the Android section below.

**No other software required.** Node.js is bundled inside the installer.

---

## Android

**Install `Shamlss-Android-Beta.apk`**

1. Copy the APK to your phone
2. Open it — Android will ask to allow installs from unknown sources. Allow it.
3. Install, then open Shamlss
4. Enter your PC's local IP address (e.g. `192.168.1.x`) and tap Connect

To find your PC's IP: open the Shamlss tray app on your PC → the tooltip shows the address (e.g. `My Node · :7432`). Your IP is whatever your PC's local network address is (Start → search "network status" → see the IPv4 address).

---

## Headless Server (Linux / macOS / Windows without the tray app)

Use these if you want Shamlss running on a server without a desktop.

**Linux:**
```bash
bash install-server-linux.sh
```
Installs Node.js if needed, sets up a systemd service that starts on boot.

**macOS:**
```bash
bash install-server-macos.sh
```
Installs Node.js via Homebrew if needed, sets up a LaunchAgent that starts on login.

**Windows (server-only, no tray):**
```powershell
# Run in PowerShell as Administrator
.\install-server-windows.ps1
```
Installs Node.js if needed, adds a startup entry, launches the server.

---

## Adding music

Once Shamlss is running, open `http://localhost:7432/ui` in a browser:

1. Click **Settings** → **Add Music Folder**
2. Paste the path to your music folder (e.g. `C:\Users\You\Music`)
3. Click **Scan** — Shamlss indexes everything

---

## Ports

Shamlss uses:
- **TCP 7432** — web player, API, streaming
- **UDP 7433** — LAN device discovery (optional)

If you have a firewall, allow TCP 7432 from your local network.

---

## Log file
`%APPDATA%\.shamlss\daemon.log` (Windows) or `~/.shamlss/daemon.log` (Linux/macOS)

---

## Known beta limitations
- No code signing — Windows/Android may show an "untrusted" warning. This is expected for beta.
- Lock-screen media controls not yet implemented on Android
- iOS and macOS apps require building from source (Xcode/Apple developer account needed)
