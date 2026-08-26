#!/usr/bin/env bash
#
# make-playlist.sh — build the channel's running order.
#
# Writes a playlist in FFmpeg's "concat demuxer" format: a plain text file
# listing, in order, every clip the channel should play. One line each:
#
#     file '/absolute/path/to/clip.mp4'
#
# The playout process reads this once at startup and plays straight through it,
# then loops back to the top. Idents and ad breaks are cut in between programs
# so the channel feels like television rather than a folder on shuffle.
#
# Usage:  ./scripts/make-playlist.sh
# Output: stream/playlist.txt
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLAYLIST="$ROOT/stream/playlist.txt"

# ---------------------------------------------------------------------------
# add <path> — append one clip to the playlist.
#
# Fails if the file is missing. A playlist pointing at a file that
# isn't there kills the playout process the moment it reaches that line, and
# the FFmpeg error is not obvious about which line was at fault.
# ---------------------------------------------------------------------------
add() {
    local f="$1"
    if [[ ! -f "$f" ]]; then
        echo "ERROR: missing clip: $f" >&2
        echo "Run ./scripts/make-test-clips.sh first." >&2
        exit 1
    fi
    # Single quotes around the path: the concat demuxer needs them, and they
    # allow spaces in filenames.
    echo "file '$f'" >> "$PLAYLIST"
}

P="$ROOT/media/programs"
I="$ROOT/media/idents"
A="$ROOT/media/ads"

# Start fresh every run.
: > "$PLAYLIST"

# ---------------------------------------------------------------------------
# The running order.
#
# Pattern: ident -> program -> ad break -> ident -> program -> ...
# ---------------------------------------------------------------------------

add "$I/ident.mp4"
add "$P/01-agent-327.mp4"
add "$A/ad-apple.mp4"
add "$A/ad-ronaldo.mp4"

add "$I/ident.mp4"
add "$P/02-cute-monkey.mp4"
add "$A/ad-cola.mp4"

add "$I/ident.mp4"
add "$P/03-wing-it.mp4"
add "$A/ad-beyonce.mp4"
add "$A/ad-ronaldo.mp4"

add "$I/ident.mp4"          
add "$P/04-squirrel-munching.mp4"
add "$A/ad-cola.mp4"

add "$I/ident.mp4"           
add "$P/05-silly-space-robo.mp4"
add "$A/ad-ronaldo.mp4"
add "$A/ad-apple.mp4"         

add "$I/ident.mp4"          
add "$P/06-coffee-run.mp4"  
add "$A/ad-beyonce.mp4"

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
COUNT=$(wc -l < "$PLAYLIST" | tr -d ' ')

TOTAL=0
while read -r _ path; do
    path="${path%\'}"            # strip trailing quote
    path="${path#\'}"            # strip leading quote
    d=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$path")
    TOTAL=$(echo "$TOTAL + $d" | bc)
done < "$PLAYLIST"

echo "Wrote $PLAYLIST"
echo "  $COUNT items"
printf "  %.0f seconds per full cycle (%.1f minutes)\n" "$TOTAL" "$(echo "$TOTAL / 60" | bc -l)"
echo
cat -n "$PLAYLIST"