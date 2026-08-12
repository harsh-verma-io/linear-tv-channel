#!/usr/bin/env bash
#
# playout.sh — the channel. One FFmpeg process that never exits.
#
# Reads the playlist, plays every clip end to end, loops back to the top, and
# writes a continuous HLS stream into stream/.
#
# Usage:
#   ./scripts/playout.sh                 # 6-second segments (default)
#   SEGMENT_TIME=2 ./scripts/playout.sh  # 2-second segments 
#
# Stop it with Ctrl-C.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLAYLIST="$ROOT/stream/playlist.txt"
OUT="$ROOT/stream"

# --- Channel format. Must match scripts/make-test-clips.sh. -----------------
FPS=30
GOP=60                                   # keyframe every 2s
VIDEO_BITRATE=2500k
AUDIO_BITRATE=128k

# --- HLS tuning. -----------------------------------------------------------
SEGMENT_TIME="${SEGMENT_TIME:-6}"        # seconds per segment
PLAYLIST_SIZE="${PLAYLIST_SIZE:-6}"      # how many segments exist in manifest
# ---------------------------------------------------------------------------
# Check if playlist exists
# ---------------------------------------------------------------------------
if [[ ! -f "$PLAYLIST" ]]; then
    echo "ERROR: no playlist at $PLAYLIST" >&2
    echo "Run ./scripts/make-playlist.sh first." >&2
    exit 1
fi

# Clear last run's segments. Old .ts files left behind confuse a player that
# reconnects, and they quietly consume disk.
rm -f "$OUT"/*.ts "$OUT"/*.m3u8


echo "================================================================"
echo " CHANNEL ON AIR"
echo "----------------------------------------------------------------"
echo " playlist       : $PLAYLIST"
echo " output         : $OUT/index.m3u8"
echo " segment length : ${SEGMENT_TIME}s"
echo " manifest holds : ${PLAYLIST_SIZE} segments"
echo " keyframes      : every ${GOP} frames (${FPS}fps = $((GOP / FPS))s)"
echo "----------------------------------------------------------------"
echo " Ctrl-C to stop"
echo "================================================================"
echo

exec ffmpeg -hide_banner -loglevel warning -stats \
    \
    `# --- INPUT ---------------------------------------------------------` \
    -re \
    -stream_loop -1 \
    -f concat -safe 0 -i "$PLAYLIST" \
    \
    `# --- VIDEO ENCODE --------------------------------------------------` \
    -c:v libx264 -preset veryfast -profile:v main -pix_fmt yuv420p \
    -g "$GOP" -keyint_min "$GOP" -sc_threshold 0 \
    -b:v "$VIDEO_BITRATE" -maxrate "$VIDEO_BITRATE" -bufsize 5000k \
    \
    `# --- AUDIO ENCODE --------------------------------------------------` \
    -c:a aac -b:a "$AUDIO_BITRATE" -ar 48000 -ac 2 \
    \
    `# --- HLS OUTPUT ----------------------------------------------------` \
    -f hls \
    -hls_time "$SEGMENT_TIME" \
    -hls_list_size "$PLAYLIST_SIZE" \
    -hls_flags delete_segments+program_date_time+independent_segments \
    -hls_segment_type mpegts \
    -hls_segment_filename "$OUT/segment_%05d.ts" \
    "$OUT/index.m3u8"