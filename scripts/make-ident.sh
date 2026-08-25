#!/usr/bin/env bash
#
# make-ident.sh — generate the channel ident.
#
# Usage:  ./scripts/make-ident.sh
# Output: media/idents/ident.mp4
#
set -euo pipefail

# --- Channel format. Must match scripts/make-test-clips.sh. ----------------
WIDTH=1280
HEIGHT=720
FPS=30
GOP=60
SAMPLE_RATE=48000
CHANNELS=2
AUDIO_BITRATE=128k

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/media/idents/ident.mp4"

FONT=""
for f in "/System/Library/Fonts/Supplemental/Arial.ttf" \
         "/System/Library/Fonts/Helvetica.ttc"
do
    if [[ -f "$f" ]]; then FONT="$f"; break; fi
done
[[ -n "$FONT" ]] || { echo "ERROR: no usable font found." >&2; exit 1; }

# ---------------------------------------------------------------------------
# The music.
#
# FFmpeg has no instruments, only sine waves. A chord is therefore several
# sines mixed together, and a progression is several of those played one after
# another. Four notes per chord, four chords, looping.
#
# The progression used is I - vi - ii - V in C to mimic elevator music.
#
# A pure sine cutting straight to another one clicks, so each chord fades in
# and out by a fraction of a second at its edges.
# ---------------------------------------------------------------------------
BEAT=2.5                 # seconds per chord
EDGE=0.08                # click-avoiding fade at each chord boundary
TREMOLO_HZ=5             # the vibraphone wobble
MUSIC_VOLUME=5.11        # under the picture, not over it

FADE_AT=$(awk "BEGIN{print $BEAT - $EDGE}")
DURATION=$(awk "BEGIN{print $BEAT * 4}")
OUTRO_AT=$(awk "BEGIN{print $DURATION - 1}")

FC=""        # the filter graph, built up piece by piece
CHORDS=""    # the labels to hand to concat at the end

# chord <number> <frequency...>
chord() {
    local idx="$1"; shift
    local n=0 mix=""

    for hz in "$@"; do
        n=$((n + 1))
        FC+="sine=f=${hz}:r=${SAMPLE_RATE}:d=${BEAT}[c${idx}n${n}];"
        mix+="[c${idx}n${n}]"
    done

    FC+="${mix}amix=inputs=${n}:normalize=1"
    FC+=",afade=t=in:st=0:d=${EDGE}"
    FC+=",afade=t=out:st=${FADE_AT}:d=${EDGE}[c${idx}];"

    CHORDS+="[c${idx}]"
}

#      C4      E4      G4      B4
chord 1 261.63 329.63 392.00 493.88     # Cmaj7   I
#      A3      C4      E4      G4
chord 2 220.00 261.63 329.63 392.00     # Am7     vi
#      D4      F4      A4      C5
chord 3 293.66 349.23 440.00 523.25     # Dm7     ii
#      G3      B3      D4      F4
chord 4 196.00 246.94 293.66 349.23     # G7      V

# Join the four chords end to end, then treat the result as one piece of music.
FC+="${CHORDS}concat=n=4:v=0:a=1"
FC+=",tremolo=f=${TREMOLO_HZ}:d=0.35"
FC+=",volume=${MUSIC_VOLUME}"
FC+=",afade=t=in:st=0:d=1"
FC+=",afade=t=out:st=${OUTRO_AT}:d=1[a];"

# ---------------------------------------------------------------------------
# The picture. Two lines of text over colour bars.
# ---------------------------------------------------------------------------
FC+="[0:v]drawtext=fontfile=${FONT}:text='SIX SEVEN'"
FC+=":fontcolor=white:fontsize=110:box=1:boxcolor=black@0.6:boxborderw=30"
FC+=":x=(w-text_w)/2:y=(h/2)-text_h-20"
FC+=",drawtext=fontfile=${FONT}:text='BACK SHORTLY'"
FC+=":fontcolor=white:fontsize=46:box=1:boxcolor=black@0.6:boxborderw=18"
FC+=":x=(w-text_w)/2:y=(h/2)+40[v]"

echo "Generating ${DURATION}s ident: Cmaj7 - Am7 - Dm7 - G7"

ffmpeg -hide_banner -loglevel error -stats -y \
    -f lavfi -i "smptebars=size=${WIDTH}x${HEIGHT}:rate=${FPS}:duration=${DURATION}" \
    -filter_complex "$FC" \
    -map "[v]" -map "[a]" \
    -c:v libx264 -preset veryfast -profile:v main -level 4.0 -pix_fmt yuv420p \
    -g "$GOP" -keyint_min "$GOP" -sc_threshold 0 \
    -c:a aac -b:a "$AUDIO_BITRATE" -ar "$SAMPLE_RATE" -ac "$CHANNELS" \
    -movflags +faststart \
    "$OUT"

echo
echo "Wrote $OUT"
ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT" \
    | awk '{printf "  %.2f seconds\n", $1}'
ffprobe -v error -select_streams v:0 \
    -show_entries stream=codec_name,width,height,r_frame_rate,pix_fmt \
    -of csv=p=0 "$OUT" | sed 's/^/  video: /'
ffprobe -v error -select_streams a:0 \
    -show_entries stream=codec_name,sample_rate,channels \
    -of csv=p=0 "$OUT" | sed 's/^/  audio: /'
