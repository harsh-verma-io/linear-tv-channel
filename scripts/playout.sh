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
#   SOURCE=camera ./scripts/playout.sh   # live from the built-in camera
#   SOURCE=camera CAMERA=1:0 ./...       # a different device
#
# List camera devices with:
#   ffmpeg -f avfoundation -list_devices true -i ""
#
# Stop it with Ctrl-C.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLAYLIST="$ROOT/stream/playlist.txt"
OUT="$ROOT/stream"

# --- Channel format. Must match scripts/make-test-clips.sh. -----------------
WIDTH=1280               # only used by the camera; files use their own
HEIGHT=720
FPS=30
GOP=60                                   # keyframe every 2s
VIDEO_BITRATE=2500k
AUDIO_BITRATE=128k

# --- HLS tuning. -----------------------------------------------------------
SEGMENT_TIME="${SEGMENT_TIME:-6}"        # seconds per segment
PLAYLIST_SIZE="${PLAYLIST_SIZE:-6}"      # how many segments exist in manifest

# --- Where the frames come from. -------------------------------------------
SOURCE="${SOURCE:-playlist}"
CAMERA="${CAMERA:-0:0}"                  # video:audio device index

case "$SOURCE" in
    playlist)
        # -re paces the file to real time. Without it FFmpeg would read the
        # whole playlist as fast as the disk allows.
        INPUT=(-re -stream_loop -1 -f concat -safe 0 -i "$PLAYLIST")
        ;;
    camera)
        # No -re. A camera cannot be slowed down; it already produces frames
        # at exactly one speed, because that is how fast reality happens.
        INPUT=(-f avfoundation -framerate "$FPS"
               -video_size "${WIDTH}x${HEIGHT}" -pix_fmt nv12 -i "$CAMERA")
        ;;
    *)
        echo "ERROR: SOURCE must be 'playlist' or 'camera', got '$SOURCE'" >&2
        exit 1
        ;;
esac

# --- Stamped wall-clock. CLOCK=0 to turn it off. ---------------------------
# Stamps wall-clock time onto every outgoing frame, so the delay between what
# the channel is producing and what a viewer sees becomes visible to the eye.
CLOCK="${CLOCK:-1}"

# Monospace fonts used since proportional digits change width as they tick, so the
# clock visibly jitters.
FONT=""
for f in "/System/Library/Fonts/Supplemental/Courier New.ttf" \
         "/System/Library/Fonts/Supplemental/Arial.ttf" \
         "/System/Library/Fonts/Helvetica.ttc"
do
    if [[ -f "$f" ]]; then FONT="$f"; break; fi
done

if [[ "$CLOCK" == "1" && -n "$FONT" ]]; then
    VF="drawtext=fontfile=${FONT}:text='%{localtime\\:%T}'"
    VF+=":fontcolor=white:fontsize=48:box=1:boxcolor=black@0.65:boxborderw=16"
    VF+=":x=(w-text_w)/2:y=30"
else
    VF="null"          # passthrough — the filter chain still needs to exist
fi

# --- Second output over SRT. SRT=0 to turn it off. -------------------------
# Two destinations through one encoder. Identical frames and identical wall-clock
# go to both, so any difference we might see is transport, not encoding.
SRT="${SRT:-1}"
SRT_PORT="${SRT_PORT:-9999}"

# onfail=ignore on both, so losing one output never kills the channel.
HLS_OPTS="f=hls"
HLS_OPTS+=":hls_time=${SEGMENT_TIME}"
HLS_OPTS+=":hls_list_size=${PLAYLIST_SIZE}"
HLS_OPTS+=":hls_flags=delete_segments+program_date_time+independent_segments"
HLS_OPTS+=":hls_segment_type=mpegts"
HLS_OPTS+=":hls_segment_filename=${OUT}/segment_%05d.ts"
HLS_OPTS+=":onfail=ignore"

TEE="[${HLS_OPTS}]${OUT}/index.m3u8"

if [[ "$SRT" == "1" ]]; then
    TEE+="|[f=mpegts:onfail=ignore]srt://127.0.0.1:${SRT_PORT}?mode=caller"
fi

# ---------------------------------------------------------------------------
# Check if playlist exists
# ---------------------------------------------------------------------------
if [[ "$SOURCE" == "playlist" && ! -f "$PLAYLIST" ]]; then
    echo "ERROR: no playlist at $PLAYLIST" >&2
    echo "Run ./scripts/make-playlist.sh first." >&2
    exit 1
fi

# Clear last run's segments. Old .ts files left behind confuse a player that
# reconnects, and they quietly consume disk.
rm -f "$OUT"/*.ts "$OUT"/*.m3u8

# --- Program guide. GUIDE=0 to turn it off. --------------------------------
# Records what is about to play and the moment it starts, so the guide can
# work out what is on air later. Deliberately non-fatal: set -e would
# otherwise let a database issue stop the channel over a missing guide.
GUIDE="${GUIDE:-1}"
VENV_PY="$ROOT/.venv/bin/python"

if [[ "$GUIDE" == "1" && "$SOURCE" == "playlist" ]]; then
    if [[ -x "$VENV_PY" ]]; then
        "$VENV_PY" "$ROOT/app/start_broadcast.py" \
            || echo "WARNING: guide not recorded. The channel will run without it." >&2
    else
        echo "WARNING: no .venv found, skipping the guide." >&2
    fi
fi

echo "================================================================"
echo " CHANNEL ON AIR"
echo "----------------------------------------------------------------"
if [[ "$SOURCE" == "camera" ]]; then
    echo " source         : camera $CAMERA (live)"
else
    echo " source         : $PLAYLIST"
fi
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
    "${INPUT[@]}" \
    \
    `# --- FILTERS -------------------------------------------------------` \
    -vf "$VF" \
    \
    `# --- VIDEO ENCODE --------------------------------------------------` \
    -c:v libx264 -preset veryfast -profile:v main -pix_fmt yuv420p \
    -g "$GOP" -keyint_min "$GOP" -sc_threshold 0 \
    -b:v "$VIDEO_BITRATE" -maxrate "$VIDEO_BITRATE" -bufsize 5000k \
    \
    `# --- AUDIO ENCODE --------------------------------------------------` \
    -c:a aac -b:a "$AUDIO_BITRATE" -ar 48000 -ac 2 \
    \
    `# --- TWO OUTPUTS FROM ONE ENCODE -----------------------------------` \
    -f tee -map 0:v -map 0:a "$TEE"