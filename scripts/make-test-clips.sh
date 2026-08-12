#!/usr/bin/env bash
#
# make-test-clips.sh — generate synthetic test content for the channel.
#
# Produces programs, idents and ad clips that are BYTE-FOR-BYTE CONSISTENT in
# every parameter that matters to the playout loop: resolution, frame rate,
# pixel format, codec profile, keyframe interval, sample rate, channel layout.
#
# Mismatch in any one of those parameters can cause the stream to die at a
# program boundary. Generating content guarantees consistency, so if the
# playout loop breaks, it's easier to troubleshoot; as we know it is the loop 
# and not the media.
#
# Usage:  ./scripts/make-test-clips.sh
#
set -euo pipefail

# -----------------------------------------------------------------------------------
# Channel-wide format. Every file the channel ever plays must match these parameters.
# -----------------------------------------------------------------------------------
WIDTH=1280
HEIGHT=720
FPS=30
GOP=60              # keyframe every 60 frames = every 2 seconds at 30fps
SAMPLE_RATE=48000
CHANNELS=2

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---------------------------------------------------------------------------
# Find a usable font for drawtext, from font files on disk.
# ---------------------------------------------------------------------------
FONT=""
for item in \
    "/System/Library/Fonts/Supplemental/Arial.ttf" \
    "/System/Library/Fonts/Supplemental/Courier New.ttf" \
    "/System/Library/Fonts/Helvetica.ttc" \
    "/Library/Fonts/Arial.ttf"
do
    if [[ -f "$item" ]]; then FONT="$item"; break; fi
done

if [[ -z "$FONT" ]]; then
    echo "ERROR: no usable font found."
    exit 1
fi
echo "Using font: $FONT"

# ---------------------------------------------------------------------------
# make_clip <output> <duration> <video source> <audio hz> <big label>
# ---------------------------------------------------------------------------
make_clip() {
    local out="$1" dur="$2" vsrc="$3" hz="$4" label="$5"

    # Two text overlays:
    #   1. the clip's name, centred — so you can see which file is on air
    #   2. a running clip-local timecode — so a freeze or stall is obvious
    local vf="drawtext=fontfile=${FONT}:text='${label}':fontcolor=white:fontsize=96"
    vf+=":box=1:boxcolor=black@0.55:boxborderw=28:x=(w-text_w)/2:y=(h-text_h)/2"
    vf+=",drawtext=fontfile=${FONT}:text='%{pts\\:hms}':fontcolor=yellow:fontsize=52"
    vf+=":box=1:boxcolor=black@0.55:boxborderw=16:x=(w-text_w)/2:y=h-text_h-70"

    echo "  -> $(basename "$out")  (${dur}s)"

    ffmpeg -hide_banner -loglevel error -y \
        -f lavfi -i "${vsrc}=size=${WIDTH}x${HEIGHT}:rate=${FPS}:duration=${dur}" \
        -f lavfi -i "sine=frequency=${hz}:sample_rate=${SAMPLE_RATE}:duration=${dur}" \
        -vf "$vf" \
        -c:v libx264 -preset veryfast -profile:v main -level 4.0 -pix_fmt yuv420p \
        -g "$GOP" -keyint_min "$GOP" -sc_threshold 0 \
        -c:a aac -b:a 128k -ar "$SAMPLE_RATE" -ac "$CHANNELS" \
        -movflags +faststart \
        -shortest \
        "$out"
}

echo
echo "Generating programs..."
make_clip "$ROOT/media/programs/01-morning-show.mp4"  20 testsrc2   220 "PROGRAM 1"
make_clip "$ROOT/media/programs/02-nature-doc.mp4"    20 testsrc2   330 "PROGRAM 2"
make_clip "$ROOT/media/programs/03-trivia-night.mp4"    20 rgbtestsrc 440 "PROGRAM 3"
make_clip "$ROOT/media/programs/04-late-movie.mp4"    20 testsrc2   550 "PROGRAM 4"

echo
echo "Generating idents..."
make_clip "$ROOT/media/idents/ident-a.mp4"  6 smptebars 660 "CHANNEL 4"
make_clip "$ROOT/media/idents/ident-b.mp4"  6 smptebars 880 "BACK SHORTLY"

echo
echo "Generating ads..."
make_clip "$ROOT/media/ads/ad-01.mp4" 12 rgbtestsrc 300 "AD BREAK 1"
make_clip "$ROOT/media/ads/ad-02.mp4" 12 rgbtestsrc 400 "AD BREAK 2"
make_clip "$ROOT/media/ads/ad-03.mp4" 12 testsrc2   500 "AD BREAK 3"

echo
echo "Done. Verifying every clip has an identical format signature:"
echo
printf "%-30s  %-34s  %s\n" "FILE" "VIDEO (codec,w,h,pixfmt,fps)" "AUDIO (codec,rate,ch)"
printf "%-30s  %-34s  %s\n" "------------------------------" "----------------------------------" "---------------------"

find "$ROOT/media" -name '*.mp4' | sort | while read -r f; do
    v=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=codec_name,width,height,r_frame_rate,pix_fmt \
        -of csv=p=0 "$f")
    a=$(ffprobe -v error -select_streams a:0 \
        -show_entries stream=codec_name,sample_rate,channels \
        -of csv=p=0 "$f")
    printf "%-30s  %-34s  %s\n" "$(basename "$f")" "$v" "$a"
done

echo
echo "Every row above must be identical apart from the filename."
echo
echo "Keyframe check on one clip (expect an I roughly every ${GOP} frames):"
ffprobe -v error -select_streams v:0 -show_entries frame=pict_type -of csv=p=0 \
    "$ROOT/media/programs/01-morning-show.mp4" | tr -d '\n' | head -c 130
echo