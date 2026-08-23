-- schema.sql — latency lab storage.

-- Apply with:  psql -d tvchannel -f db/schema.sql

-- ---------------------------------------------------------------------------
-- runs — one row per run. Written once, when a run starts.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS runs (
    id            BIGSERIAL PRIMARY KEY,
    started_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    label         TEXT        NOT NULL,   -- "seg=2s, sync=1"

    -- encoder knobs (playout.sh)
    segment_time  REAL        NOT NULL,   -- REAL, not INT: LL-HLS uses 0.5
    playlist_size INT         NOT NULL,

    -- player knobs (index.html)
    sync_count    INT         NOT NULL,   -- liveSyncDurationCount

    -- network knob (nginx limit_rate); NULL = unthrottled
    throttle_kbps INT,

    protocol      TEXT        NOT NULL DEFAULT 'hls',
    startup_ms    INT,                    -- time to first frame
    user_agent    TEXT
);

-- ---------------------------------------------------------------------------
-- samples — one row per reading from the viewer page, a few seconds apart.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS samples (
    id             BIGSERIAL PRIMARY KEY,

    run_id         BIGINT      NOT NULL REFERENCES runs(id) ON DELETE CASCADE,

    recorded_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    latency_s      REAL,
    buffer_ahead_s REAL,
    dropped_frames INT,
    total_frames   INT,
    stall_count    INT,
    playback_rate  REAL
);

CREATE INDEX IF NOT EXISTS samples_run_time ON samples (run_id, recorded_at);