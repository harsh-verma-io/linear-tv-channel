"""
latency_log.py — the measurement API.

Endpoints:

    GET  /api/health          health check
    POST /api/run             start of a run -> {run_id}
    POST /api/sample          reading taken during that run
    GET  /api/guide?at=...    what is on air at a given moment

Usage:

    .venv/bin/python app/latency_log.py

Listens on 127.0.0.1:5001 — localhost
"""

import os
from datetime import datetime, timedelta, timezone

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

# ---------------------------------------------------------------------------
# GET /api/guide — what is on air at a given moment.
# ---------------------------------------------------------------------------
UPCOMING = 20          # how many items to list beyond "next"
LIST_KIND = "program"  # what the listing shows; "now" is never filtered

@app.get("/api/guide")
def guide():
    at_param = request.args.get("at")
    if at_param:
        try:
            # Browsers send "…Z" for UTC; fromisoformat wants "+00:00".
            at = datetime.fromisoformat(at_param.replace("Z", "+00:00"))
        except ValueError:
            return jsonify(error=f"bad timestamp: {at_param}"), 400
        if at.tzinfo is None:
            at = at.replace(tzinfo=timezone.utc)
    else:
        # No ?at= means "right now", which makes the endpoint easy to curl.
        at = datetime.now(timezone.utc)

    try:
        with psycopg.connect(DSN) as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    SELECT id, started_at, cycle_s
                    FROM broadcasts
                    ORDER BY started_at DESC
                    LIMIT 1
                    """
                )
                row = cur.fetchone()
                if row is None:
                    return jsonify(error="no broadcast recorded"), 404
                broadcast_id, started_at, cycle_s = row

                cur.execute(
                    """
                    SELECT position, title, kind, offset_s, duration_s
                    FROM broadcast_items
                    WHERE broadcast_id = %s
                    ORDER BY position
                    """,
                    (broadcast_id,),
                )
                items = [
                    {"position": r[0], "title": r[1], "kind": r[2],
                     "offset_s": r[3], "duration_s": r[4]}
                    for r in cur.fetchall()
                ]
    except psycopg.Error as e:
        return jsonify(error=str(e)), 500

    if not items:
        return jsonify(error=f"broadcast {broadcast_id} has no items"), 500

    # How far into the loop.
    elapsed = (at - started_at).total_seconds()
    position_s = elapsed % cycle_s

    # The last item that has already begun.
    index = 0
    for i, item in enumerate(items):
        if item["offset_s"] > position_s:
            break
        index = i

    def described(i, starts_at):
        item = items[i]
        return {
            "position": item["position"],
            "title": item["title"],
            "kind": item["kind"],
            "duration_s": round(item["duration_s"], 1),
            "starts_at": starts_at.isoformat(),
            "ends_at": (starts_at
                        + timedelta(seconds=item["duration_s"])).isoformat(),
        }

    into = position_s - items[index]["offset_s"]
    cursor = at - timedelta(seconds=into)

    now = described(index, cursor)
    now["remaining_s"] = round(items[index]["duration_s"] - into, 1)

    # Step through every item, but only list the programmes.
    schedule = []
    cursor += timedelta(seconds=items[index]["duration_s"])

    wanted = UPCOMING + 1                  # "next", plus the upcoming list
    limit = len(items) * wanted            # stop rather than spin

    n = 1
    while len(schedule) < wanted and n <= limit:
        i = (index + n) % len(items)
        if items[i]["kind"] == LIST_KIND:
            schedule.append(described(i, cursor))
        cursor += timedelta(seconds=items[i]["duration_s"])
        n += 1

    return jsonify(
        broadcast_id=broadcast_id,
        at=at.isoformat(),
        cycle_s=round(cycle_s, 1),
        now=now,
        next=schedule[0] if schedule else None,
        upcoming=schedule[1:],
    )

if __name__ == "__main__":
    # host="127.0.0.1" and not "0.0.0.0": this must not be reachable from the
    # network. There is no authentication here to protect our database.
    app.run(host="127.0.0.1", port=PORT, debug=True)