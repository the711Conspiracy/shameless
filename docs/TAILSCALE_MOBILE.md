# Remote Access via Tailscale — Flutter Integration Notes

This document describes what the Flutter mobile app needs to do to connect over
Tailscale instead of a local LAN IP. The Tailscale integration lives entirely in
the daemon (`/tailscale/*` endpoints); the Flutter side changes are small.

---

## How it works end-to-end

```
Phone (Tailscale VPN active)
  └─ Shamlss app → HTTP to 100.x.x.x:7432
                    │
          [Tailscale mesh — key exchange via coordinator only]
                    │
              PC daemon (100.x.x.x:7432)
                    └─ streams audio directly to phone
```

The Tailscale coordination server handles key exchange. Audio bytes travel
directly phone→daemon over the encrypted Tailscale mesh; nothing proxied through
the coordinator.

---

## Setup flow (user perspective)

1. On the PC: open Shamlss web UI → Settings → Remote Access
2. Click "Enable Remote Access" → daemon calls `GET /tailscale/auth`
3. A QR code appears — user scans it **with the Tailscale mobile app** (not Shamlss)
   to join the PC's tailnet
4. Tailscale assigns the PC a stable IP like `100.x.x.x`
5. On the phone: open the Tailscale app, confirm the connection
6. In Shamlss mobile app: go to Settings → change server address from `192.168.x.x`
   to the Tailscale IP shown in the daemon's Remote Access panel

---

## Daemon API reference (for the Flutter client)

| Endpoint | Method | Purpose |
|---|---|---|
| `/tailscale/status` | GET | State (`Running`/`NeedsLogin`/`NotInstalled`), Tailscale IP |
| `/tailscale/auth` | GET | Start auth flow — returns `{ auth_url, qr }` or 503 if not installed |
| `/tailscale/up` | POST | Connect with `{ auth_key?, login_server? }` for headless setup |
| `/tailscale/down` | POST | Disconnect from tailnet |
| `/tailscale/config` | GET / PATCH | Read/update `coordinator_url`, `hostname` |

### Status response shape
```json
{
  "available": true,
  "state": "Running",
  "hostname": "shamlss-node",
  "tailscale_ip": "100.64.0.1",
  "coordinator_url": "https://controlplane.tailscale.com"
}
```

### Auth response shape (when login needed)
```json
{
  "auth_url": "https://login.tailscale.com/a/...",
  "qr": "data:image/png;base64,..."
}
```

---

## What the Flutter app needs to change

### 1. `ConnectScreen` — accept Tailscale IPs

The connect screen already accepts a free-text IP. No code change needed.
Tailscale IPs are in the `100.64.0.0/10` range (CGNAT), so they look like
`100.64.0.1` — users can type them directly. LAN discovery (`UDP :7433`)
won't find Tailscale peers, but that's expected.

**Optional UX improvement**: add a hint under the address field:
> "Over Tailscale? Enter the IP shown in the desktop app's Remote Access panel."

### 2. `SettingsScreen` — Remote Access section

Add a new section that polls `GET /tailscale/status` and:

- **Not installed**: show "Install Tailscale on this device to enable remote access"
  with a link to tailscale.com/download.
- **NeedsLogin**: show a "Connect" button that calls `GET /tailscale/auth` on the
  **daemon** (not the phone) and displays the returned QR code so the user can
  scan it with Tailscale.
- **Running**: show the Tailscale IP in a copyable field:
  `Remote address: 100.x.x.x:7432`.

```dart
// Skeleton — add to settings_screen.dart

Future<Map<String, dynamic>?> _fetchTailscaleStatus() async {
  final r = await http.get(
    Uri.parse('${widget.daemon.baseUrl}/tailscale/status'),
  ).timeout(const Duration(seconds: 5));
  if (r.statusCode == 403) return null;  // feature disabled
  return jsonDecode(r.body) as Map<String, dynamic>;
}

Future<Map<String, dynamic>?> _startTailscaleAuth() async {
  final r = await http.get(
    Uri.parse('${widget.daemon.baseUrl}/tailscale/auth'),
  ).timeout(const Duration(seconds: 15));
  if (r.statusCode != 200) return null;
  return jsonDecode(r.body) as Map<String, dynamic>;
}
```

The `qr` field from `/tailscale/auth` is a PNG data URL — render it with:
```dart
Image.memory(base64Decode(qrDataUrl.split(',')[1]))
```

### 3. No changes needed in `DaemonClient` or `ShamlssPlayer`

All audio streaming happens over the normal HTTP API (`/stream/:id`). Once the
phone is on the Tailscale network and the address is set to the Tailscale IP,
everything else is transparent.

---

## Headscale self-hosting

To use a self-hosted [Headscale](https://headscale.net) coordination server
instead of Tailscale's, call:

```
PATCH /tailscale/config
{ "coordinator_url": "https://headscale.yourdomain.com" }
```

The daemon passes `--login-server=URL` to `tailscale up` automatically.
All other behaviour is identical.

---

## Installing Tailscale

| Platform | Command |
|---|---|
| Windows | `winget install Tailscale.Tailscale` |
| macOS | `brew install tailscale` |
| Linux (Debian/Ubuntu) | `curl -fsSL https://tailscale.com/install.sh \| sh` |
| Android / iOS | Install **Tailscale** from Play Store / App Store |

After install, the daemon's `GET /tailscale/status` will report
`"state": "NoState"` or `"NeedsLogin"` instead of `"NotInstalled"`.
