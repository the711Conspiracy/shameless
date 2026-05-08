# Shamlss — LLM Agent Briefing

## What Is This
Self Hosted Audio Music Library Streaming Service. A fully local, P2P music streaming app. No cloud. No central server. Users host their own music library on their PC; a Flutter app streams it over LAN/WAN. Friends share music by joining a "pod" — a cryptographically closed swarm, torrent-style. One user can belong to many pods simultaneously; one daemon handles all of them.

The "A" in Shamlss may one day stand for AI if the agents earn it through contribution. The tone is shameless — own your stack, reject cloud.

## Stack
| Layer | Tech |
|---|---|
| Desktop daemon | Node.js + Electron (bundled runtime, system tray) |
| Mobile + desktop client | Flutter (Windows, Android confirmed; iOS planned) |
| Transport | HTTPS range requests (audio) + WebSocket (real-time events) |
| Pod discovery | mDNS (LAN auto) + manual IP (WAN, no cloud) |
| Database | SQLite (embedded, local only) |
| Crypto | ed25519 keypairs, self-signed TLS, cert pinning |
| AI (optional) | Ollama local inference only — no API keys, no internet |

## Node Identity vs Pod Identity — CRITICAL DISTINCTION
Every user has ONE node identity (ed25519 keypair, permanent, never transmitted). They have MANY pod keypairs (one per pod, membership tokens). These are separate:
- Node identity = who you are
- Pod keypair = proof of membership in a specific pod
- A peer who shares two pods with you sees the same node cert, different pod tokens
- Node identity compromise → rotate once → reissues all pod tokens (fan-out)
- Pod key rotation → kicks all pod members → forces re-pair for that pod only

## Multi-Pod Architecture
Each daemon is a single hub managing all pod memberships:
```
Node (one daemon, one port, one identity keypair)
|-- pod_registry
|     |-- pod: "metal_heads"  -- role: host   -- scope: /music/metal
|     |-- pod: "college_crew" -- role: member -- scope: /music/all
|-- peer_registry (deduplicated across ALL pods)
      |-- alice -- cert_pin, last_ip, pods_shared: [metal_heads, college_crew]
```
- All pods served on ONE port. Inbound requests carry Pod-ID header + pod-signed token. pod-router module routes internally.
- Library manifests generated per-request, scoped to pod_id. Cross-pod data leakage is architecturally impossible.
- Same physical peer in multiple pods = one connection, multiple pod contexts. No duplicate connections.

## Security Model — CRITICAL
- In-person pairing only. Guest scans QR shown on host screen. QR = one-time nonce (60s TTL) + host IP + pod pubkey. Expired or reused nonces rejected.
- TLS everywhere. Self-signed cert per node. Cert pinned at pairing time. Unknown certs hard-rejected.
- All requests signed with pod keypair. Unsigned or wrong-pod requests rejected before any data access.
- No passive broadcasts. Daemon exposes no open ports until user explicitly opens a pairing session.
- Host controls membership. Can revoke individual member, rotate pod key (forces all to re-pair), or nuke pod entirely.
- Per-member library visibility. Full library / selected folders / hidden. Enforced at manifest generation, not at file serving.

## Pod Networking (Torrent-Style, Closed Swarm)
- No tracker — members exchange peer lists directly via signed gossip protocol
- Audio split into 256KB chunks, each chunk hash-verified against host-signed manifest
- Members who have cached chunks serve them to others automatically
- Multi-source assembly: phone pulls chunks from N peers in parallel
- Host going offline mid-stream degrades gracefully if others hold cached chunks

## Full Data Model
```
Node
  node_id (hash of pubkey)
  identity_keypair (permanent, encrypted at rest)
  display_name
  self_signed_cert

Pod
  pod_id
  pod_keypair (per-pod membership token)
  my_role: host | member
  host_node_id (null if I am host)
  library_scope: [folder_paths]
  members[]: Member

Member
  node_id
  display_name
  cert_pin
  visibility_scope: full | folders | hidden
  shared_pods[]: pod_id
  last_seen_ip
  last_seen_port
  last_seen_ts

Library (local)
  folders[]: watched_path
  tracks[]: Track

Track
  id (content hash)
  path (local)
  title, artist, album, year, genre
  duration, bitrate, format
  album_art_hash
  analysis: { bpm, key, loudness, mood_vector }  <- populated by track-analysis

Queue (transient, in-memory)
  items[]: { track_id, source_node_id, pod_id, position }

Playlist
  id, name, pod_id (null = personal)
  type: manual | pod_mix | mood | smart
  items[]: { track_id, source_node_id }

Cache
  chunks[]: { track_id, chunk_index, data, verified_ts }
  total_size, max_size (user config)
```

## Module Map
| Module | Responsibility | Called By |
|---|---|---|
| crypto | ed25519 ops, cert gen/pin, key storage, rotation | pairing, peer, pod-router |
| pod-router | Route requests by pod, validate tokens, scope manifests, dedup peers | ALL network features |
| library | Track index, tag parse, file watch, manifest gen | scanner, search, streaming, analysis |
| audio-engine | Playback, queue, seek, gapless, crossfade | local play, remote play, DJ, social |
| peer | Connection pool, signed request wrapper, TLS, reconnect | streaming, mesh, social, chat |
| track-analysis | BPM, key, loudness, mood vectors, embeddings (ollama) | recommendations, auto-mix, smart shuffle |
| cache | Chunk store, LRU eviction, integrity check, serve to peers | mesh, offline mode |
| events | Internal pub/sub bus — modules never import each other directly | all modules |
| feature-flags | Runtime on/off per feature ID, reads config/features.json | all features |

## Code Conventions
- Every unimplemented hook: `// HOOK: P<phase> <feature_id> <description>`
- No external API calls. No telemetry. No analytics. No CDN imports at runtime.
- All network calls go through pod-router first — never raw peer calls from features.
- Feature flags in config/features.json — all false by default, flipped per phase.
- Each phase adds a module to src/modules/. Core modules are never modified after Phase 1.
- AI features always check ollama availability first, fall back to heuristics silently.

## Key Constraints
1. Zero cloud — must work fully offline on LAN
2. One port, one daemon, all pods
3. Manifests scoped per pod at generation time, never cached globally
4. In-person QR pairing is the only way to join a pod, ever
5. Peer deduplication across pods handled by pod-router, not individual features
6. Audio uses HTTP 206 range requests — compatible with Flutter audio plugins

## What NOT To Do
- Never broadcast node presence without explicit user action
- Never store data outside local SQLite / local filesystem
- Never accept unsigned, cert-unpinned, or wrong-pod-token requests
- Never allow remote pod joining (no invite links, no email, no SMS)
- Never let feature modules talk to each other directly — use events bus
- Never cache a library manifest without scoping it to a specific pod_id
