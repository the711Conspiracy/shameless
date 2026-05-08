const Database = require('better-sqlite3')
const path = require('path')
const os = require('os')
const fs = require('fs')

const dataDir = path.join(os.homedir(), '.shamlss')
if (!fs.existsSync(dataDir)) fs.mkdirSync(dataDir, { recursive: true })

const db = new Database(path.join(dataDir, 'shamlss.db'))

db.exec(`
  PRAGMA journal_mode=WAL;

  CREATE TABLE IF NOT EXISTS nodes (
    node_id TEXT PRIMARY KEY,
    pubkey TEXT NOT NULL,
    cert TEXT NOT NULL,
    display_name TEXT NOT NULL,
    created_ts INTEGER NOT NULL
  );

  CREATE TABLE IF NOT EXISTS pods (
    pod_id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    my_role TEXT NOT NULL,
    my_keypair_enc TEXT NOT NULL,
    host_node_id TEXT,
    created_ts INTEGER NOT NULL
  );

  CREATE TABLE IF NOT EXISTS pod_scopes (
    pod_id TEXT NOT NULL,
    folder_path TEXT NOT NULL,
    PRIMARY KEY (pod_id, folder_path)
  );

  CREATE TABLE IF NOT EXISTS pod_members (
    pod_id TEXT NOT NULL,
    node_id TEXT NOT NULL,
    display_name TEXT NOT NULL,
    cert_pin TEXT NOT NULL,
    visibility TEXT NOT NULL DEFAULT 'full',
    joined_ts INTEGER NOT NULL,
    revoked_ts INTEGER,
    PRIMARY KEY (pod_id, node_id)
  );

  CREATE TABLE IF NOT EXISTS peers (
    node_id TEXT PRIMARY KEY,
    last_ip TEXT,
    last_port INTEGER,
    last_seen_ts INTEGER
  );

  CREATE TABLE IF NOT EXISTS peer_pods (
    node_id TEXT NOT NULL,
    pod_id TEXT NOT NULL,
    PRIMARY KEY (node_id, pod_id)
  );

  CREATE TABLE IF NOT EXISTS tracks (
    id TEXT PRIMARY KEY,
    path TEXT NOT NULL,
    title TEXT,
    artist TEXT,
    album TEXT,
    year INTEGER,
    genre TEXT,
    duration INTEGER,
    bitrate INTEGER,
    format TEXT,
    art_hash TEXT,
    file_hash TEXT NOT NULL,
    indexed_ts INTEGER NOT NULL
  );

  CREATE TABLE IF NOT EXISTS track_analysis (
    track_id TEXT PRIMARY KEY,
    bpm REAL,
    musical_key TEXT,
    loudness REAL,
    mood_vector BLOB,
    embedding BLOB,
    fingerprint TEXT,
    analyzed_ts INTEGER
  );

  CREATE TABLE IF NOT EXISTS playlists (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    pod_id TEXT,
    type TEXT NOT NULL DEFAULT 'manual',
    created_ts INTEGER NOT NULL
  );

  CREATE TABLE IF NOT EXISTS playlist_tracks (
    playlist_id TEXT NOT NULL,
    track_id TEXT NOT NULL,
    source_node_id TEXT,
    position INTEGER NOT NULL,
    PRIMARY KEY (playlist_id, position)
  );

  CREATE TABLE IF NOT EXISTS chunks (
    track_id TEXT NOT NULL,
    chunk_index INTEGER NOT NULL,
    data BLOB NOT NULL,
    hash TEXT NOT NULL,
    verified_ts INTEGER NOT NULL,
    last_accessed_ts INTEGER NOT NULL,
    orphan_ts INTEGER,
    PRIMARY KEY (track_id, chunk_index)
  );

  CREATE TABLE IF NOT EXISTS play_history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    track_id TEXT NOT NULL,
    source_node_id TEXT,
    pod_id TEXT,
    played_ts INTEGER NOT NULL,
    duration_ms INTEGER
  );

  CREATE TABLE IF NOT EXISTS nonces (
    nonce TEXT PRIMARY KEY,
    exp INTEGER NOT NULL
  );
`)

// Migrations — idempotent column additions
const existingCols = db.pragma('table_info(tracks)').map(c => c.name)
if (!existingCols.includes('loudness')) db.exec('ALTER TABLE tracks ADD COLUMN loudness REAL')
if (!existingCols.includes('replay_gain')) db.exec('ALTER TABLE tracks ADD COLUMN replay_gain REAL')
if (!existingCols.includes('type')) db.exec("ALTER TABLE tracks ADD COLUMN type TEXT NOT NULL DEFAULT 'music'")

const existingAnalysisCols = db.pragma('table_info(track_analysis)').map(c => c.name)
if (!existingAnalysisCols.includes('waveform')) db.exec('ALTER TABLE track_analysis ADD COLUMN waveform TEXT')

db.exec(`
  CREATE TABLE IF NOT EXISTS collab_queue (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    track_id TEXT NOT NULL,
    source_node_id TEXT,
    added_by TEXT,
    added_ts INTEGER NOT NULL,
    played_ts INTEGER
  );

  CREATE TABLE IF NOT EXISTS listening_party (
    id TEXT PRIMARY KEY,
    host_node_id TEXT NOT NULL,
    track_id TEXT,
    position_ms INTEGER DEFAULT 0,
    playing INTEGER DEFAULT 0,
    updated_ts INTEGER
  );

  CREATE TABLE IF NOT EXISTS track_reactions (
    id TEXT PRIMARY KEY,
    track_id TEXT NOT NULL,
    node_id TEXT NOT NULL,
    emoji TEXT NOT NULL,
    ts INTEGER NOT NULL
  );

  CREATE TABLE IF NOT EXISTS chat_messages (
    id TEXT PRIMARY KEY,
    pod_id TEXT,
    node_id TEXT NOT NULL,
    display_name TEXT,
    body TEXT NOT NULL,
    ts INTEGER NOT NULL
  );

  CREATE TABLE IF NOT EXISTS offline_cache (
    track_id TEXT PRIMARY KEY,
    file_path TEXT NOT NULL,
    file_size INTEGER,
    cached_ts INTEGER NOT NULL
  );

  CREATE INDEX IF NOT EXISTS idx_track_reactions_track ON track_reactions(track_id, ts DESC);
  CREATE INDEX IF NOT EXISTS idx_chat_messages_pod ON chat_messages(pod_id, ts DESC);

  CREATE TABLE IF NOT EXISTS track_chapters (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    track_id TEXT NOT NULL,
    position_ms INTEGER NOT NULL,
    title TEXT,
    UNIQUE(track_id, position_ms)
  );

  CREATE TABLE IF NOT EXISTS track_resume (
    track_id TEXT PRIMARY KEY,
    position_ms INTEGER NOT NULL,
    updated_ts INTEGER NOT NULL
  );
`)

module.exports = db
