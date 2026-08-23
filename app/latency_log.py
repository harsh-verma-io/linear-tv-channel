"""
latency_log.py — the measurement API.

Endpoints:

    GET  /api/health          health check
    POST /api/run             start of a run -> {run_id}
    POST /api/sample          reading taken during that run

Usage:

    .venv/bin/python app/latency_log.py

Listens on 127.0.0.1:5001 — localhost
"""

import os

import psycopg
from flask import Flask, jsonify, request

# Port 5001, not 5000: macOS runs AirPlay Receiver on 5000
PORT = int(os.environ.get("PORT", 5001))
DSN = os.environ.get("DATABASE_URL", "dbname=tvchannel")

app = Flask(__name__)

# ---------------------------------------------------------------------------
# One connection per request.
# ---------------------------------------------------------------------------
def insert(sql, params):
    """Run one INSERT and hand back the first column."""
    with psycopg.connect(DSN) as conn:
        with conn.cursor() as cur:
            cur.execute(sql, params)
            row = cur.fetchone()
    # Leaving the `with` block commits the SQL. An exception rolls back instead.
    return row[0] if row else None


@app.get("/api/health")
def health():
    """Tests if Flask & Postgres are up and running."""
    try:
        with psycopg.connect(DSN) as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT count(*) FROM samples")
                count = cur.fetchone()[0]
        return jsonify(ok=True, samples=count)
    except psycopg.Error as e:
        return jsonify(ok=False, error=str(e)), 500


# ---------------------------------------------------------------------------
# POST /api/run — one row, written once, when the page loads.
# ---------------------------------------------------------------------------
@app.post("/api/run")
def start_run():
    body = request.get_json(silent=True) or {}

    # The four knobs that define a condition. Throw an error if any are missing.
    required = ("label", "segment_time", "playlist_size", "sync_count")
    missing = [k for k in required if body.get(k) is None]
    if missing:
        return jsonify(error=f"missing: {', '.join(missing)}"), 400

    try:
        run_id = insert(
            # %s placeholders, NOT f-strings. psycopg passes the SQL and the 
            # values separately, so Postgres parses the query before it ever 
            # sees the values. Thus, making it secure against SQL injection.
            """
            INSERT INTO runs (label, segment_time, playlist_size, sync_count,
                              throttle_kbps, protocol, startup_ms, user_agent)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
            RETURNING id
            """,
            (
                body["label"],
                body["segment_time"],
                body["playlist_size"],
                body["sync_count"],
                body.get("throttle_kbps"),          # None -> SQL NULL
                body.get("protocol", "hls"),
                body.get("startup_ms"),
                request.headers.get("User-Agent"),  # the browser tells us
            ),
        )
    except psycopg.Error as e:
        return jsonify(error=str(e)), 500

    # 201, not 200: since something was created.
    return jsonify(run_id=run_id), 201


# ---------------------------------------------------------------------------
# POST /api/sample — one row every few seconds for the life of the run.
# ---------------------------------------------------------------------------
@app.post("/api/sample")
def add_sample():
    body = request.get_json(silent=True) or {}

    if body.get("run_id") is None:
        return jsonify(error="missing: run_id"), 400

    try:
        sample_id = insert(
            """
            INSERT INTO samples (run_id, latency_s, buffer_ahead_s,
                                 dropped_frames, total_frames, stall_count,
                                 playback_rate)
            VALUES (%s, %s, %s, %s, %s, %s, %s)
            RETURNING id
            """,
            (
                body["run_id"],
                body.get("latency_s"),
                body.get("buffer_ahead_s"),
                body.get("dropped_frames"),
                body.get("total_frames"),
                body.get("stall_count"),
                body.get("playback_rate"),
            ),
        )
    except psycopg.errors.ForeignKeyViolation:
        # The schema's foreign key violation. A client bug, not a server one,
        # so 400 instead of 500.
        return jsonify(error=f"no such run: {body['run_id']}"), 400
    except psycopg.Error as e:
        return jsonify(error=str(e)), 500

    return jsonify(ok=True, sample_id=sample_id), 201


if __name__ == "__main__":
    # host="127.0.0.1" and not "0.0.0.0": this must not be reachable from the
    # network. There is no authentication here to protect our database.
    app.run(host="127.0.0.1", port=PORT, debug=True)