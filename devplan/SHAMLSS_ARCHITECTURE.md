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
Generates nonce  + QR payload,  signed, 60s TTL.  Guest scans,
verifies nonce, sends signed request; host verifies, returns
pod_keypair_encrypted_for_guest and member manifest.  PAIRED.
```

## Request Authentication Flow
Every request after pairing carries Pod-ID, Node-ID, Authorization (session
token signed with pod keypair), and Timestamp headers.  pod-router:
1. Look up pod_id in pod_registry.
2. Look up node_id in member list for that pod.
3. Verify signature against stored cert_pin.
4. Check timestamp within +/-30s.
5. Check member not revoked.
6. Resolve library_scope for this node_id in this pod.
7. Dispatch.
On any failure: generic 401.  No detail in response.  Log locally only.

## Multi-Pod Peer Deduplication
One connection per node_id regardless of how many pods are shared.  Peer
registry is keyed by node_id; pods field lists all pods in common.  IP
changes detected once, updated once.

## Library Scoping
manifest_for(node_id, pod_id):
1. Get pod from pod_registry.
2. Get member visibility_scope for node_id in that pod.
3. If hidden → return empty manifest.
4. If folders → filter library to those paths only.
5. If full → return full library.
6. Sign with pod keypair.
7. Return.
Never cache manifest without pod_id in the cache key.

## Revocation & Key Rotation
Revoking member X from pod P: remove X from member list, generate new pod
keypair, re-encrypt for remaining members, push via signed WS event.
Rotating node identity is nuclear: generate new keypair + cert, fan-out to
all pods, old connections rejected.

## Failure Modes
- Host offline: greyed status, cached chunks still playable.
- Clock skew > 30s: session tokens rejected, user prompted.
- Daemon crash: SQLite intact, reconnects automatically on restart.
- Pod key rotation mid-stream: current stream completes, new key for next req.

## SQLite Schema
nodes, pods, pod_scopes, pod_members, peers, peer_pods, tracks,
track_analysis, playlists, playlist_tracks, chunks, play_history,
nonces (single-use, TTL-based).

## Directory Structure
Daemon: shamlss-daemon/src/{core, modules/{crypto,pod-router,library,
audio-engine,peer,track-analysis,cache,events,stream}, phases}, config/
features.json, data/.
Flutter: shamlss_flutter/lib/{main.dart, core/{daemon_client,player,
theme,crypto_store,pod_router_client}, screens/{connect,library,
now_playing,pods,settings,pairing}, modules/*}.
