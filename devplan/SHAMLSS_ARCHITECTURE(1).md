# Shamlss — Architecture & Multi-Pod Design

## The Core Problem This Document Solves
A user will belong to many pods simultaneously. Each pod is a separate cryptographic context. One daemon must handle all of them safely, without cross-pod data leakage, without UX complexity, and without requiring multiple running processes.

## Node-as-Hub Model
```
    +-------------------------------------+
    |         Shamlss Daemon              |
    | (one process, one port, one SQLite) |
    |                                     |
Inbound request --> |    pod-router                       |
Pod-ID: metal_heads |     | validate pod token            |
Token: <signed>     |     | scope to pod context          |
                    |     | resolve peer identity         |
                    |     | dispatch to feature handler   |
                    |                                     |
                    |    Pod Registry (SQLite)            |
                    |     | metal_heads (host)            |
                    |     | members: alice, bob           |
                    |     | college_crew (member)         |
                    |     | host: alice_node              |
                    |                                     |
                    |    Peer Registry (deduplicated)     |
                    |     | alice: cert_pin, ip, port     |
                    |     | pods: [metal, college]        |
                    +-------------------------------------+
```

## Identity Hierarchy
```
Level 1 -- Node Identity (permanent, one per installation)
  ed25519 keypair
  self-signed TLS cert (derived from keypair)
  never transmitted directly -- cert_pin shared at pairing

Level 2 -- Pod Keypair (one per pod joined)
  ed25519 keypair, distinct from node identity
  membership proof -- knowing the pod keypair = authorization
  rotatable independently of node identity

Level 3 -- Session Token (ephemeral)
  signed by pod keypair
  short-lived, used to authenticate individual HTTP/WS requests
  prevents replay attacks
```

## Pairing Flow (In-Person, Required)
```
Host (daemon)                              Guest (Flutter app)
--------------------------------------------------------
User opens "Add Member"
Generates nonce (random 32 bytes)
Generates QR payload:
  { pod_id, pod_pubkey, host_ip,
    host_port, nonce, nonce_exp }
Signs payload with pod keypair
Displays QR on screen (60s TTL)
                                            User scans QR
                                            Validates nonce_exp > now
                                            Sends to host:
                                              { guest_node_pubkey,
                                                guest_cert,
                                                nonce (echo) }
                                            Signs with guest node key
Verifies nonce matches + unexpired
Verifies guest signature
Stores guest cert_pin
Sends back:
  { pod_keypair_encrypted_for_guest,
    member_list_manifest,
    host_cert }
Signs with host pod keypair
                                            Pins host cert
                                            Stores pod keypair
                                            Stores member list
                                            PAIRED
```

## Request Authentication Flow

Every request after pairing:
```
1. Flutter sends: GET /manifest
   Headers:
     Pod-ID: metal_heads
     Node-ID: <hash of node pubkey>
     Authorization: <session token signed with pod keypair>
     Timestamp: <unix ms>

2. pod-router receives:
   a. Look up pod_id in pod_registry
   b. Look up node_id in member list for that pod
   c. Verify Authorization signature against stored member cert
   d. Check timestamp within +/-30s (replay protection)
   e. Check member not revoked
   f. Scope request to pod's library_scope
   g. Dispatch

3. On failure: 401. No detail. Log locally only.
```

## Multi-Pod Peer Deduplication
```
Scenario: Alice is in both "metal_heads" and "college_crew"

WITHOUT dedup (naive):
  Connection to Alice for metal_heads
  Connection to Alice for college_crew   <-- duplicate, wasteful
  If Alice's IP changes, must update both

WITH peer_registry dedup (correct):
  peer_registry["alice_node_id"] = {
    cert_pin: "abc123",
    current_ip: "192.168.1.42",
    current_port: 7432,
    pods: ["metal_heads", "college_crew"],
    connection: <single active connection>
  }
  Requests for either pod routed over same connection
  IP change detected once, updated once
```

## Library Scoping (Cross-Pod Leak Prevention)
```
manifest_for(node_id, pod_id):
  1. Get pod from pod_registry where pod_id matches
  2. Get member visibility_scope for node_id in that pod
  3. If hidden   -> return empty manifest
  4. If folders  -> filter library to those paths only
  5. If full     -> return full library
  6. Sign manifest with pod keypair
  7. Return

NEVER:
  - Cache manifest without pod_id scope key
  - Return manifest before step 3 check
  - Use global library object directly in any network handler
```

## Revocation & Key Rotation
```
Revoke member X from pod P:
  1. Remove X from pod P member list
  2. Generate new pod keypair for P
  3. Re-encrypt new pod keypair for each remaining member
  4. Push new keypair to online members via signed WebSocket event
  5. Online members: swap pod keypair, continue
  6. Offline members: next connection attempt fails auth -> prompted to re-pair
  7. X's old pod keypair is now useless -- cannot forge valid session tokens

Rotate node identity (nuclear option):
  1. Generate new node keypair + cert
  2. For each pod in pod_registry:
     a. If host: push new host cert to all members
     b. If member: send re-pair request to host
  3. Old cert revoked, connections using it rejected
```

## Failure Modes & Graceful Degradation
| Scenario | Behavior |
|---|---|
| Host goes offline | Members see greyed status. Cached chunks still playable. Manifest still browsable from cache. |
| Partial pod online | Multi-source assembly uses available peers. Missing chunks waited on or skipped. |
| Clock skew > 30s | Session tokens rejected. User prompted to check system clock. |
| Pod key rotation while streaming | Current stream completes on old key. New key required for next request. |
| Daemon crash | SQLite intact. On restart, reconnects to known peers automatically. Queue lost (transient). |
| New member joins large pod | Receives member list manifest. Connects to peers incrementally, not all at once. |
| Two users pair simultaneously | Nonces are single-use. Second pairing attempt with same nonce rejected. |

## SQLite Schema Overview
```sql
-- Core identity
nodes (node_id PK, pubkey, cert, display_name, created_ts)

-- Pod membership
pods (pod_id PK, name, my_role, my_keypair_enc, host_node_id, created_ts)
pod_scopes (pod_id FK, folder_path)
pod_members (pod_id FK, node_id FK, display_name, cert_pin, visibility, joined_ts, revoked_ts)

-- Peer network state
peers (node_id PK, last_ip, last_port, last_seen_ts)
peer_pods (node_id FK, pod_id FK)  -- junction: which pods we share

-- Library
tracks (id PK, path, title, artist, album, year, genre, duration,
        bitrate, format, art_hash, file_hash, indexed_ts)
track_analysis (track_id FK, bpm, musical_key, loudness, mood_vector BLOB,
                embedding BLOB, analyzed_ts)

-- Playlists & Queue (queue is session-only, cleared on restart)
playlists (id PK, name, pod_id, type, created_ts)
playlist_tracks(playlist_id FK, track_id, source_node_id, position)

-- Cache
chunks (track_id FK, chunk_index, data BLOB, hash, verified_ts, last_accessed_ts)

-- History
play_history (track_id FK, source_node_id, pod_id, played_ts, duration_ms)

-- Nonces (single-use, TTL-based)
nonces (nonce PK, exp_ts, consumed_ts)
```

## Directory Structure (Daemon)
```
shamlss-daemon/
  src/
    core/
      identity.js      <-- F01: node keypair, cert gen
      db.js            <-- SQLite connection, migrations
      config.js        <-- feature flags, user prefs
    modules/
      crypto/          <-- sign, verify, encrypt, rotate, fingerprint
      pod-router/      <-- request routing, scoping, dedup
      library/         <-- scanner, watcher, manifest gen
      audio-engine/    <-- playback, queue, seek
      peer/            <-- connections, TLS, signed requests
      track-analysis/  <-- BPM, key, mood, ollama bridge
      cache/           <-- chunks, LRU, seeding
      events/          <-- pub/sub bus
      stream/          <-- HTTP 206 range streaming (F19/F21)
    phases/            <-- one folder per phase, loaded by feature-flags
      p2-pairing/
      p4-streaming/
      p6-mesh/
      ...
  config/
    features.json      <-- all false by default
  data/                <-- SQLite db, cert, keypairs (never in repo)
```

## Flutter App Structure
```
shamlss_flutter/
  lib/
    main.dart              <-- MiniPlayer, IndexedStack nav, player wiring
    core/
      daemon_client.dart   <-- HTTP + WS connection to daemon
      player.dart          <-- ShamlssPlayer (just_audio wrapper, queue)
      theme.dart           <-- deep space aesthetic
      crypto_store.dart    <-- cert pins, pod tokens (flutter_secure_storage)
      pod_router_client.dart <-- sends Pod-ID + signed tokens
    screens/
      connect_screen.dart
      library_screen.dart     <-- platform-conditional (mobile=browse, desktop=folder add)
      now_playing_screen.dart
      pods_screen.dart
      settings_screen.dart
      pairing/                <-- QR scanner (Phase 2)
    modules/                  <-- one folder per phase feature
      streaming/
      mesh/
      social/
      ...
```
