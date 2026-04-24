-- Local SQLite schema for the offline sleep tracker.
-- Keep this file in sync with rust/crates/sleep-core/src/db/schema.rs (embedded via include_str!).

CREATE TABLE IF NOT EXISTS sessions (
    id             TEXT PRIMARY KEY,
    user_id        TEXT NOT NULL,
    started_at_ms  INTEGER NOT NULL,
    ended_at_ms    INTEGER,
    uploaded       INTEGER NOT NULL DEFAULT 0,
    created_at_ms  INTEGER NOT NULL DEFAULT (strftime('%s','now') * 1000)
);

-- Kind codes:
--  1 = heart_rate    (value_json: numeric bpm as text)
--  2 = accelerometer (value_json: {"x":,"y":,"z":})
--  3 = audio_event   (value_json: {"kind":"snore","score":..})  DEFAULT not stored unless user opts in
--  4 = hrv           (value_json: {"sdnn":..,"rmssd":..})
CREATE TABLE IF NOT EXISTS samples (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id   TEXT NOT NULL,
    ts_ms        INTEGER NOT NULL,
    kind         INTEGER NOT NULL,
    value_json   TEXT NOT NULL,
    FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_samples_session_ts ON samples(session_id, ts_ms);

CREATE TABLE IF NOT EXISTS stage_timeline (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id   TEXT NOT NULL,
    ts_ms        INTEGER NOT NULL,
    stage        INTEGER NOT NULL,      -- 0=Wake 1=Light 2=Deep 3=Rem
    confidence   REAL NOT NULL,
    FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_stage_session_ts ON stage_timeline(session_id, ts_ms);

-- Reserved for future audio-event storage. DISABLED by default at application layer
-- (settings.save_raw_audio=false, settings.audio_upload_enabled=false).
CREATE TABLE IF NOT EXISTS audio_events (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id   TEXT NOT NULL,
    ts_ms        INTEGER NOT NULL,
    event_kind   TEXT NOT NULL,        -- e.g. 'snore','cough','env'
    score        REAL NOT NULL,
    clip_blob    BLOB,                 -- always NULL unless user explicitly opts in
    FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS settings (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

-- Privacy-conservative defaults.
INSERT OR IGNORE INTO settings (key, value) VALUES ('audio_upload_enabled', 'false');
INSERT OR IGNORE INTO settings (key, value) VALUES ('save_raw_audio',       'false');
INSERT OR IGNORE INTO settings (key, value) VALUES ('cloud_sync_enabled',   'false');
INSERT OR IGNORE INTO settings (key, value) VALUES ('share_with_healthkit', 'false');

CREATE TABLE IF NOT EXISTS model_metadata (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    name         TEXT NOT NULL,
    version      TEXT NOT NULL,
    checksum     TEXT,
    installed_at_ms INTEGER NOT NULL DEFAULT (strftime('%s','now') * 1000)
);

-- Reserved even though we do not sync to any backend in this milestone.
CREATE TABLE IF NOT EXISTS sync_queue (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    entity_type  TEXT NOT NULL,   -- 'session' | 'summary'
    entity_id    TEXT NOT NULL,
    enqueued_at_ms INTEGER NOT NULL DEFAULT (strftime('%s','now') * 1000),
    status       TEXT NOT NULL DEFAULT 'pending'
);
