#!/usr/bin/env bash
#
# experiment.sh — run one measured condition, automated start to finish.
#
# Usage:
#
#   ./scripts/experiment.sh --seg 6 --sync 3 --minutes 10
#   ./scripts/experiment.sh --seg 2 --sync 1 --minutes 10
#   ./scripts/experiment.sh --seg 6 --sync 3 --minutes 60          # drift run
#   ./scripts/experiment.sh --seg 6 --sync 3 --throttle 400        # see note
#
# Requires nginx and app/latency_log.py to already be running.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- Defaults. Each one can be overridden by a flag. -----------------------
SEG=6              # seconds per segment      -> playout.sh SEGMENT_TIME
WINDOW=6           # segments in the manifest -> playout.sh PLAYLIST_SIZE
SYNC=3             # segments behind live     -> index.html liveSyncDurationCount
MINUTES=10         # how long to measure
THROTTLE=""        # kbps, for the record only — see the warning below

BASE_URL="http://localhost:8888"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

# Separate Chrome profile. Without this, the flags below will be silently
# ignored whenever normal Chrome is already running — the new window just
# joins the existing process and inherits its settings.
CHROME_PROFILE="/tmp/tv-lab-profile"

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --seg)      SEG="$2";      shift 2 ;;
        --window)   WINDOW="$2";   shift 2 ;;
        --sync)     SYNC="$2";     shift 2 ;;
        --minutes)  MINUTES="$2";  shift 2 ;;
        --throttle) THROTTLE="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "unknown option: $1" >&2
            echo "try: $0 --help" >&2
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Pre-checks
# ---------------------------------------------------------------------------
fail() { echo "ERROR: $*" >&2; exit 1; }

[[ -f "$ROOT/stream/playlist.txt" ]] \
    || fail "no playlist. Run ./scripts/make-playlist.sh first."

[[ -x "$CHROME" ]] \
    || fail "Chrome not found at: $CHROME"

# -f makes curl exit non-zero on a 4xx/5xx rather than printing the error body
# and reporting success. -s keeps it silent.
curl -fs "$BASE_URL/api/health" >/dev/null \
    || fail "API not answering at $BASE_URL/api/health.
       Start it:  .venv/bin/python app/latency_log.py
       And check nginx:  brew services list"

# The page cannot detect nginx's rate limit, so it has to be declared.
if [[ -n "$THROTTLE" ]]; then
    cat <<WARN

  ! --throttle ${THROTTLE} only records the number. It does not apply it.
  ! Uncomment limit_rate in nginx/tv-channel.conf and reload nginx first,
  ! and make sure the value matches.

WARN
    read -rp "  limit_rate is set to ${THROTTLE}k in nginx? [y/N] " ok
    [[ "$ok" == "y" ]] || fail "aborted."
fi

# ---------------------------------------------------------------------------
# Build the viewer URL
# ---------------------------------------------------------------------------
URL="${BASE_URL}/?sync=${SYNC}"
[[ -n "$THROTTLE" ]] && URL="${URL}&throttle=${THROTTLE}"

# ---------------------------------------------------------------------------
# Shutdown. Runs on normal exit and on Ctrl-C, so an abandoned run does not
# leave FFmpeg encoding to an unattended browser.
# ---------------------------------------------------------------------------
PLAYOUT_PID=""
CHROME_PID=""

cleanup() {
    echo
    echo "Stopping..."
    [[ -n "$CHROME_PID"  ]] && kill "$CHROME_PID"  2>/dev/null || true
    [[ -n "$PLAYOUT_PID" ]] && kill "$PLAYOUT_PID" 2>/dev/null || true
    pkill -f "user-data-dir=${CHROME_PROFILE}" 2>/dev/null || true
    wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "================================================================"
echo " EXPERIMENT"
echo "----------------------------------------------------------------"
printf " segment length : %ss\n"        "$SEG"
printf " manifest holds : %s segments\n" "$WINDOW"
printf " player sits    : %s segments behind live\n" "$SYNC"
printf " duration       : %s minutes\n"  "$MINUTES"
printf " throttle       : %s\n"          "${THROTTLE:-none}"
echo "================================================================"
echo

# ---------------------------------------------------------------------------
# 1. The channel.
#
# playout.sh ends in `exec ffmpeg`, so this PID is FFmpeg itself — killing it
# stops the encode directly, with no shell left orphaned in between.
# ---------------------------------------------------------------------------
echo "[1/4] Starting playout (${SEG}s segments)..."
SEGMENT_TIME="$SEG" PLAYLIST_SIZE="$WINDOW" \
    "$ROOT/scripts/playout.sh" >/tmp/tv-playout.log 2>&1 &
PLAYOUT_PID=$!

# ---------------------------------------------------------------------------
# 2. Wait for a full manifest.
#
# Measuring before the window has filled would record a player starved of
# segments — a startup artefact, not the steady state we are comparing.
# ---------------------------------------------------------------------------
echo "[2/4] Waiting for ${WINDOW} segments..."
DEADLINE=$(( $(date +%s) + (SEG * WINDOW * 2) + 30 ))

while :; do
    kill -0 "$PLAYOUT_PID" 2>/dev/null || fail "playout died. See /tmp/tv-playout.log"

    count=$(grep -c '^#EXTINF' "$ROOT/stream/index.m3u8" 2>/dev/null) || count=0
    [[ "$count" -ge "$WINDOW" ]] && break

    [[ $(date +%s) -gt $DEADLINE ]] && fail "manifest never filled (got ${count}/${WINDOW})"
    sleep 1
done
echo "      manifest full."

# ---------------------------------------------------------------------------
# 3. The viewer.
#
# Chrome slows timers in tabs that are in background OR merely covered by
# another window. These three flags will turn that off, and the separate
# profile will make them take effect.
# ---------------------------------------------------------------------------
echo "[3/4] Opening lab browser..."
# Start from a clean profile every run.
rm -rf "$CHROME_PROFILE"
"$CHROME" \
    --disable-background-timer-throttling \
    --disable-renderer-backgrounding \
    --disable-backgrounding-occluded-windows \
    --hide-crash-restore-bubble \
    --user-data-dir="$CHROME_PROFILE" \
    --new-window \
    --autoplay-policy=no-user-gesture-required \
    "$URL" >/dev/null 2>&1 &
CHROME_PID=$!

# ---------------------------------------------------------------------------
# 4. Measure.
# ---------------------------------------------------------------------------
echo "[4/4] Measuring for ${MINUTES} minutes. Ctrl-C to stop early."
echo
for (( m = MINUTES; m > 0; m-- )); do
    printf "\r      %2d min remaining " "$m"
    sleep 60
done
printf "\r      done.                \n"

cleanup
trap - EXIT INT TERM

# ---------------------------------------------------------------------------
# Report. Read it back out of Postgres rather than from what we intended to
# do, so a run that silently failed to record is obvious immediately.
# ---------------------------------------------------------------------------
echo
psql -d tvchannel -x -c "
SELECT r.id,
       r.label,
       r.startup_ms,
       count(s.id)                        AS samples,
       round(avg(s.latency_s)::numeric, 2)  AS latency_avg,
       round(min(s.latency_s)::numeric, 2)  AS latency_min,
       round(max(s.latency_s)::numeric, 2)  AS latency_max,
       max(s.stall_count)                 AS stalls,
       max(s.dropped_frames)              AS dropped,
       max(s.total_frames)                AS total_frames
FROM runs r
LEFT JOIN samples s ON s.run_id = r.id
WHERE r.id = (SELECT max(id) FROM runs)
GROUP BY r.id, r.label, r.startup_ms;
"
