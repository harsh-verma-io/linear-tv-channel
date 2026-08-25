#!/usr/bin/env bash
#
# normalise.sh — convert every clip in media/ into the channel's consistent format.
#
# The concat demuxer joins streams together without re-encoding, so every
# clip the channel plays has to match on resolution, frame rate, pixel format,
# codec profile, sample rate and channel layout.
#
# Walks media/, converts anything that does not match the requirements, and
# replaces it in place. A clip that arrives as .avi or .mkv leaves as .mp4
# and the original is removed.
#
# Clips that already match, stay untouched; this is safe to re-run. Without
# that check every run would cost degradation of quality due to re-encoding.
#
# Usage:
#
#   ./scripts/normalise.sh              # convert what needs it
#   ./scripts/normalise.sh --dry-run    # say what it would do, change nothing
#   ./scripts/normalise.sh --force      # re-encode everything regardless
#
set -euo pipefail

# ---------------------------------------------------------------------------
# The channel format. Must match scripts/make-test-clips.sh.
# ---------------------------------------------------------------------------
WIDTH=1280
HEIGHT=720
FPS=30
GOP=60
SAMPLE_RATE=48000
CHANNELS=2
AUDIO_BITRATE=128k

# --- Loudness --------------------------------------------------------------
# Measured in LUFS, which unlike peak level tracks how loud something actually
# sounds to a person. Broadcast television uses -23 (EBU R128) or -24 (US
# ATSC). Both are quiet on laptop speakers, so streaming uses around -16,
# which is what this channel uses.
#
# TP is the true peak ceiling, kept below 0 so nothing clips after encoding.
# LRA is how much dynamic range to preserve.
LUFS=-16
TP=-1.5
LRA=11
LUFS_TOLERANCE=1.0      # how far off target a clip may sit before redoing it

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MEDIA="$ROOT/media"

fail() { echo "ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
DRY_RUN=0
FORCE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --force)   FORCE=1;   shift ;;
        -h|--help)
            sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) fail "unknown option: $1. Try: $0 --help" ;;
    esac
done

[[ -d "$MEDIA" ]] || fail "no media directory at $MEDIA"

# ---------------------------------------------------------------------------
# Video filter chain, applied in this order for a reason:
#
#   fps      first, so frames that are about to be dropped are never scaled
#   scale    fit inside the frame without distorting; the aspect is preserved
#   pad      fill the leftover with black, centred. A 4:3 film gets black
#            bars at the sides, which is what it should look like on a 16:9
#            channel rather than it being stretched sideways
#   setsar   force square pixels. Old footage often claims non-square ones,
#            which makes players stretch an already-correct picture
#   format   8-bit 4:2:0. Some sources are 10-bit or 4:2:2 and many players
#            will not touch those
# ---------------------------------------------------------------------------
VF="fps=${FPS}"
VF+=",scale=${WIDTH}:${HEIGHT}:force_original_aspect_ratio=decrease"
VF+=",pad=${WIDTH}:${HEIGHT}:(ow-iw)/2:(oh-ih)/2"
VF+=",setsar=1"
VF+=",format=yuv420p"

# ---------------------------------------------------------------------------
# Inspection
# ---------------------------------------------------------------------------

# Is this a video file at all? Cheaper to ask ffprobe than to maintain a list
# of extensions.
is_video() {
    ffprobe -v error -select_streams v:0 -show_entries stream=codec_name \
        -of csv=p=0 "$1" 2>/dev/null | grep -q .
}

has_audio() {
    ffprobe -v error -select_streams a:0 -show_entries stream=index \
        -of csv=p=0 "$1" 2>/dev/null | grep -q .
}

# Exactly the signature make-test-clips.sh prints, compared as one string.
matches_format() {
    local f="$1" v a

    [[ "${f##*.}" == "mp4" ]] || return 1

    v=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=codec_name,width,height,r_frame_rate,pix_fmt \
        -of csv=p=0 "$f" 2>/dev/null) || return 1
    [[ "$v" == "h264,${WIDTH},${HEIGHT},yuv420p,${FPS}/1" ]] || return 1

    a=$(ffprobe -v error -select_streams a:0 \
        -show_entries stream=codec_name,sample_rate,channels \
        -of csv=p=0 "$f" 2>/dev/null) || return 1
    [[ "$a" == "aac,${SAMPLE_RATE},${CHANNELS}" ]] || return 1
}

# Integrated loudness in LUFS, or empty if it cannot be measured.
measure_lufs() {
    ffmpeg -hide_banner -nostats -i "$1" -vn \
        -af "loudnorm=I=${LUFS}:TP=${TP}:LRA=${LRA}:print_format=json" \
        -f null - 2>&1 \
        | grep '"input_i"' | sed 's/.*: *"//; s/".*//'
}

# Is this clip close enough to the target loudness to leave alone?
loudness_ok() {
    local reading
    reading=$(measure_lufs "$1")

    # A generated-silence track reports -inf, which is correct and permanent.
    # Treating it as a miss would re-encode it on every single run.
    [[ "$reading" == "-inf" || -z "$reading" ]] && return 0

    awk -v got="$reading" -v want="$LUFS" -v tol="$LUFS_TOLERANCE" \
        'BEGIN { d = got - want; if (d < 0) d = -d; exit (d <= tol) ? 0 : 1 }'
}

# ---------------------------------------------------------------------------
# Conversion
# ---------------------------------------------------------------------------
encode() {
    local in="$1" out="$2"

    if ! has_audio "$in"; then
        # A lot of archive film is silent, and concat cannot join a clip that
        # has audio to one that does not. A single silent file would break the
        # whole loop, so silence gets generated instead.
        ffmpeg -hide_banner -loglevel error -stats -y \
            -i "$in" \
            -f lavfi -i "anullsrc=channel_layout=stereo:sample_rate=${SAMPLE_RATE}" \
            -vf "$VF" \
            -c:v libx264 -preset veryfast -profile:v main -level 4.0 -pix_fmt yuv420p \
            -g "$GOP" -keyint_min "$GOP" -sc_threshold 0 \
            -c:a aac -b:a "$AUDIO_BITRATE" -ar "$SAMPLE_RATE" -ac "$CHANNELS" \
            -movflags +faststart -shortest \
            "$out"
        return
    fi

    # Loudness cannot be judged from a moving window, because a quiet scene
    # followed by a loud one needs one decision for the whole file. So the
    # first pass listens to the entire thing and reports what it found, and
    # the second applies a single correction. One pass alone would pump the
    # volume up and down as the content changed.
    local measured
    measured=$(ffmpeg -hide_banner -nostats -i "$in" -vn \
        -af "loudnorm=I=${LUFS}:TP=${TP}:LRA=${LRA}:print_format=json" \
        -f null - 2>&1) || return 1

    # Pull one value out of the JSON block ffmpeg printed.
    read_json() { echo "$measured" | grep "\"$1\"" | sed 's/.*: *"//; s/".*//'; }

    local in_i in_tp in_lra in_thresh offset
    in_i=$(read_json input_i)
    in_tp=$(read_json input_tp)
    in_lra=$(read_json input_lra)
    in_thresh=$(read_json input_thresh)
    offset=$(read_json target_offset)

    [[ -n "$in_i" ]] || return 1

    printf "      %s LUFS -> %s LUFS\n" "$in_i" "$LUFS"

    # linear=true applies one flat gain across the file, which preserves the
    # original dynamics. Without the measured values it falls back to dynamic
    # mode and rides the volume as it goes.
    local af="loudnorm=I=${LUFS}:TP=${TP}:LRA=${LRA}"
    af+=":measured_I=${in_i}:measured_TP=${in_tp}:measured_LRA=${in_lra}"
    af+=":measured_thresh=${in_thresh}:offset=${offset}:linear=true"

    ffmpeg -hide_banner -loglevel error -stats -y \
        -i "$in" \
        -vf "$VF" -af "$af" \
        -c:v libx264 -preset veryfast -profile:v main -level 4.0 -pix_fmt yuv420p \
        -g "$GOP" -keyint_min "$GOP" -sc_threshold 0 \
        -c:a aac -b:a "$AUDIO_BITRATE" -ar "$SAMPLE_RATE" -ac "$CHANNELS" \
        -movflags +faststart \
        "$out"
}

# ---------------------------------------------------------------------------
# Collect the file list up front.
#
# Reading it into an array before touching anything: the loop creates
# temporary files inside media/, and a live `find` would hand them back to us
# as though they were more footage to convert.
# ---------------------------------------------------------------------------
FILES=()
while IFS= read -r f; do
    FILES+=("$f")
done < <(find "$MEDIA" -type f ! -name '.*' ! -name '*.tmp.mp4' | sort)

[[ ${#FILES[@]} -gt 0 ]] || fail "no files found under $MEDIA"

# Sweep up any temp left behind by an interrupted run.
cleanup() { find "$MEDIA" -name '*.tmp.mp4' -delete 2>/dev/null || true; }
trap cleanup EXIT INT TERM
cleanup

echo "================================================================"
echo " NORMALISE"
echo "----------------------------------------------------------------"
printf " media   : %s\n" "$MEDIA"
printf " target  : %sx%s @ %sfps, %s LUFS\n" "$WIDTH" "$HEIGHT" "$FPS" "$LUFS"
printf " files   : %s\n" "${#FILES[@]}"
[[ $DRY_RUN -eq 1 ]] && printf " mode    : dry run, nothing will be changed\n"
[[ $FORCE   -eq 1 ]] && printf " mode    : force, everything will be re-encoded\n"
echo "================================================================"
echo

CONVERTED=0
SKIPPED=0
FAILED=0

for src in "${FILES[@]}"; do
    rel="${src#"$MEDIA"/}"

    if ! is_video "$src"; then
        echo "  --  $rel  (not video, ignored)"
        continue
    fi

    # Same folder, same name, always .mp4.
    dst="${src%.*}.mp4"
    tmp="${src%.*}.tmp.mp4"

    if [[ $FORCE -eq 0 ]] && matches_format "$src" && loudness_ok "$src"; then
        echo "  ok  $rel"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        echo "  ->  $rel  (would convert)"
        CONVERTED=$((CONVERTED + 1))
        continue
    fi

    echo "  ->  $rel"

    if ! encode "$src" "$tmp"; then
        echo "      FAILED, leaving the original alone" >&2
        rm -f "$tmp"
        FAILED=$((FAILED + 1))
        continue
    fi

    # Replace only after a successful encode, so an interrupted run can never
    # leave a half-written file where a working clip used to be.
    mv "$tmp" "$dst"

    # The original is now an extra copy in a format the channel cannot play.
    [[ "$src" != "$dst" ]] && rm -f "$src"
done

trap - EXIT INT TERM
cleanup

echo
printf "converted %s, already fine %s, failed %s\n" "$CONVERTED" "$SKIPPED" "$FAILED"
[[ $FAILED -eq 0 ]] || exit 1
