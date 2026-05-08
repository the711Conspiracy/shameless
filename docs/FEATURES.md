# Shamlss — Feature Map & Module Architecture

## Shared Core Modules
Build these first. Features call modules, never each other.

| Module | Purpose | Used By |
|---|---|---|
| crypto | ed25519 sign/verify, cert gen, key storage, node/pod rotation | pairing, peer, pod-router |
| pod-router | Single-port pod multiplexing, token validation, manifest scoping, peer dedup | ALL network features |
| library | Track index, metadata parse, hash, file watch, manifest gen | scanner, search, recs, mesh |
| audio-engine | Playback, queue, seek, gapless, source-agnostic (local or remote) | all playback features |
| peer | Connection pool, signed HTTPS/WS wrapper, TLS, reconnect logic | streaming, mesh, social |
| track-analysis | BPM, key, loudness, mood vectors; ollama embeddings (optional) | recs, auto-mix, smart shuffle |
| cache | 256KB chunk store, LRU eviction, hash verify, serve to peers | mesh, offline |
| events | Internal pub/sub — modules never import each other | all modules |
| feature-flags | Runtime gate per feature ID | all features |

---

## Features

### PHASE 1 — Identity & Shell
| ID | Feature | Modules | Notes | Status |
|---|---|---|---|---|
| F01 | Generate node identity (ed25519 + self-signed TLS cert) | crypto | Uses Node.js built-in crypto (generateKeyPairSync ed25519) — libsodium-wrappers removed (WASM hangs on Windows) | DONE |
| F02 | Electron daemon — system tray, auto-start, single instance | — | Tray shell exists (shamlss-electron/main.js) but missing tray icon assets. Daemon runs standalone via `npm start`. Full Spotify-style SPA player at :7432/ui — sidebar nav, library/albums/artists tabs, sortable columns, Play All, Shuffle All, context menu, keyboard shortcuts (Space/←/→/↑↓/P/S) | PARTIAL |
| F03 | Flutter app shell — nav scaffold, stubbed screens for all phases | — | 5-tab nav: Library, Playlists, Now Playing, Pods, Settings | DONE |
| F04 | Daemon to Flutter handshake over LAN IP (manual entry) | peer, pod-router | /ping, WebSocket, auto-reconnect, host saved to SharedPreferences, auto-connect on launch | DONE |

### PHASE 2 — Pairing & Pod Management
| ID | Feature | Modules | Notes | Status |
|---|---|---|---|---|
| F05 | Host opens pairing session — generates QR (nonce+IP+pod_pubkey) | crypto, pod-router | 60s TTL, single-use nonce; host_ip included in QR payload via os.networkInterfaces() | DONE |
| F06 | Guest scans QR — completes handshake, pins host cert | crypto, pod-router | GuestScanScreen calls host pair/complete then own daemon /pods/join to persist membership | DONE |
| F07 | Pod creation (host) — name, initial library scope | pod-router, library | Creates pod keypair | DONE |
| F08 | Pod member list — view, rename, see online status | pod-router | last_seen_ts from peers JOIN; online threshold 60s | DONE |
| F09 | Revoke member — rotate pod key, notify remaining members | crypto, pod-router | Key rotated on revoke; no fan-out yet (Phase 6) | DONE |
| F10 | Per-member library visibility — full / folders / hidden | pod-router, library | Stored per member; enforced at manifest gen (pod_scopes filter) | DONE |
| F11 | Node identity rotation — reissue all pod tokens fan-out | crypto, pod-router | Single action covers all pods | TODO |

### PHASE 3 — Local Library & Playback
| ID | Feature | Modules | Notes | Status |
|---|---|---|---|---|
| F12 | Music folder scanner (ID3/FLAC/AAC/OGG tags, recursive) | library | fs.watch recursive watcher; folder.jpg/cover.jpg art fallback at index + serve time; art cached in ~/.shamlss/art/ | DONE |
| F13 | Library browse — artist / album / track views | library | TabBar: Tracks / Artists (expandable) / Albums (grid). Mobile hides folder management bar | DONE |
| F14 | Local playback + transport (play/pause/seek/skip) | audio-engine | just_audio (plain, no background service). ConcatenatingAudioSource for gapless. ReplayGain volume normalization | DONE |
| F15 | Queue — add, reorder, remove, clear | audio-engine | ReorderableListView sheet, swipe-to-remove, drag handles, jumpTo, clearAllButCurrent | DONE |
| F16 | Shuffle / repeat modes | audio-engine | Shuffle with explicit order array; repeat none/one/all cycle | DONE |
| F17 | Manual playlist — create, edit, reorder, delete | library, audio-engine | Full CRUD, track add via long-press, CSV import (Spotify + Apple Music), M3U export | DONE |
| F18 | Album art — embedded or folder.jpg fallback | library | Two-level fallback: embedded → folder.jpg at index time (cached) → folder.jpg at serve time | DONE |
| F19 | Stream track over HTTP 206 range | peer, pod-router, audio-engine | res.setHeader + res.statusCode (not res.writeHead — incompatible with Express 5). Open-ended range returns full remaining file | DONE |
| F20 | Local search — fuzzy match title/artist/album | library | Real-time filter on title/artist/album, search bar in Library AppBar | DONE |

### PHASE 4 — Remote Streaming (Host to Phone)
| ID | Feature | Modules | Notes | Status |
|---|---|---|---|---|
| F21 | Flutter audio playback via just_audio | audio-engine | just_audio_background REMOVED — caused silent init failure blocking all audio. Plain just_audio works. No lock-screen controls until re-added | DONE (Android) |
| F22 | Serve signed library manifest per pod (respects F10) | library, pod-router | GET /pods/:id/manifest — signed JSON, filtered by pod_scopes, includes stream_base; file paths stripped from response | DONE |
| F23 | Platform-conditional library screen | — | Mobile = browse only; desktop = folder add UI hidden | DONE |
| F24 | Browse pod member library (same UI as F13) | library, pod-router | PeerLibraryScreen: fetches manifest, searchable track list, tap=play, long-press=add to queue; browse button on member tile (requires last_ip) | DONE |
| F25 | Play remote track (transparent to audio-engine) | audio-engine, peer | playQueue with urlBuilder pointing to peer stream_base; _art_url/_stream_base stored in track map; MiniPlayer + NowPlaying respect _art_url | DONE |
| F26 | Peer connection status per pod member | peer, pod-router | last_seen_ts from peers JOIN; online dot in member tile (green=<60s) | DONE |

### PHASE 5 — Multi-Pod UX
| ID | Feature | Modules | Notes |
|---|---|---|---|
| F27 | Pod switcher UI — tap pod, see their context | pod-router |
| F28 | Unified peer registry — dedup peers across pods | pod-router |
| F29 | Pod-scoped everything — queue, playlists, activity all scoped | pod-router, events |
| F30 | Offline member display — greyed, library still browsable from cache | cache, pod-router |
| F31 | Same-track conflict resolution — play nearest source | peer, audio-engine |

### PHASE 6 — Pod Mesh (Torrent Model)
| ID | Feature | Modules | Notes |
|---|---|---|---|
| F32 | Chunk transfer protocol — 256KB, hash-verified, signed | peer, cache, crypto |
| F33 | Peer list gossip — members exchange peer lists directly | peer, pod-router |
| F34 | Multi-source assembly — parallel chunks from N peers | cache, audio-engine |
| F35 | Auto-seed cached chunks to pod peers | cache, peer |
| F36 | Cache management — size cap, LRU eviction, user config | cache |

### PHASE 7 — Smart Playlists & Recommendations
| ID | Feature | Modules | Notes |
|---|---|---|---|
| F37 | Track analysis pipeline — BPM, key, loudness, mood vector | track-analysis, library |
| F38 | Ollama embeddings (optional) — richer similarity | track-analysis |
| F39 | Pod Mix — auto-playlist from all pod members' libraries | track-analysis, pod-router |
| F40 | Mood playlist — energy/valence filter | track-analysis |
| F41 | More like this — cosine similarity on track vectors | track-analysis |
| F42 | Smart shuffle — mood-aware, avoids repeats | track-analysis, audio-engine |
| F43 | Listening history | audio-engine, library |
| F44 | AI playlist names/descriptions | track-analysis, ollama |

### PHASE 8 — Social Layer
| ID | Feature | Modules | Notes |
|---|---|---|---|
| F45 | Activity feed — who's playing what (opt-in per member) | peer, events, pod-router |
| F46 | Collaborative queue — pod members add to shared queue | audio-engine, peer, pod-router |
| F47 | Listening party — synchronized playback, host controls | audio-engine, peer |
| F48 | Track reactions — emoji, ephemeral | peer, events |
| F49 | Pod chat — text, E2E encrypted via pod key, LAN only | peer, crypto, pod-router |

### PHASE 9 — DJ / Advanced Audio
| ID | Feature | Modules | Notes | Status |
|---|---|---|---|---|
| F50 | Crossfade — configurable duration | audio-engine | positionStream volume fade; 0/3/5/8s options in Settings | DONE |
| F51 | Auto-mix — BPM-matched transitions using beat grid | track-analysis, audio-engine | Toggle in Settings > AUTO-MIX. When on + crossfade > 0, fade-start snaps to nearest beat boundary using current track BPM. bpmProvider callback in ShamlssPlayer fetches BPM from /analysis/:id on every track change. Handles rapid skips via _pendingBpmTrackId guard. | DONE |
| F52 | Volume normalization (ReplayGain / loudness target) | audio-engine | pow(10, gain/20) applied via setVolume on track change | DONE |
| F53 | Waveform / spectrum visualizer | audio-engine | During PCM decode (ffmpeg), computes 300-sample normalized RMS array stored in track_analysis.waveform. Served via GET /analysis/:id/waveform. WaveformPainter custom painter in NowPlayingScreen — tap to seek, amber/grey color split at playhead. Shown only when waveform data available (requires ffmpeg). | DONE |
| F54 | Sleep timer — fade out + stop | audio-engine | 15/30/45/60 min presets, 30s volume fade, cancel button in Settings | DONE |
| F55 | Gapless playback | audio-engine | ConcatenatingAudioSource with useLazyPreparation: false | DONE |

### PHASE 10 — Power Features
| ID | Feature | Modules | Notes | Status |
|---|---|---|---|---|
| F56 | WireGuard integration — WAN pods, self-hosted, no cloud | peer, pod-router | | TODO |
| F57 | Multi-room sync — cast to other daemon instances on LAN | audio-engine, peer | | TODO |
| F58 | Offline mode — full playback from cache when host offline | cache | | TODO |
| F59 | Podcast/audiobook — chapter markers, resume | library, audio-engine | | TODO |
| F60 | Lyrics — embedded LRC or .lrc sidecar | library | .lrc sidecar parsed with timestamps; embedded tag fallback via music-metadata | DONE |
| F61 | Export playlist (M3U, JSON) | library | M3U export via /playlists/:id/export.m3u | DONE |
| F62 | Import from Spotify/Apple Music (user's own CSV export) | library | POST /library/import; Spotify title+artist match, Apple Music Location path index | DONE |
| F63 | Stats dashboard — listening history, top artists, pod activity | library, events | GET /stats; play_history table; top-5 artists this week; shown in Settings screen + /ui page | DONE |

---

## Module Dependency Rules
```
feature -> pod-router -> peer -> crypto
feature -> library -> audio-engine
feature -> track-analysis (-> ollama if available)
feature -> cache
ALL cross-module communication via events bus
feature-flags gates every feature at runtime
```

## Implementation Deviations & Known Issues

| Area | Deviation | Reason |
|---|---|---|
| Crypto | libsodium-wrappers replaced with Node.js built-in `crypto.generateKeyPairSync('ed25519')` | libsodium WASM module hangs on `sodium.ready` on Windows |
| HTTPS | HTTPS server on :7433 removed | `selfsigned.generate()` (node-forge RSA) blocks event loop for 30s+ on Windows |
| Audio background | `just_audio_background` removed | Init failure was silently blocking all audio playback; plain `just_audio` works correctly |
| Daemon entry | `start()` call was missing from daemon.js | Was exported but never invoked — server never listened |
| Stream handler | `res.writeHead()` replaced with `res.setHeader()` + `res.statusCode` | `res.writeHead()` conflicts with Express 5 response model |
| Lock screen controls | Not implemented | Requires `just_audio_background` to be re-added with correct manifest setup |

## AI Policy
- Only Ollama (free, local, no API key, no internet required)
- Models: `nomic-embed-text` (similarity), `llama3.2:3b` or `qwen2.5:3b` (text generation)
- Every AI function has a heuristic fallback — Ollama absence never breaks functionality
- No model weights bundled — user installs Ollama once if they want AI features
