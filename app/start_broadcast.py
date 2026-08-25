"""
start_broadcast.py — record what the channel is about to play (program guide).

Reads stream/playlist.txt, probes each clip, and writes one broadcasts row
plus one broadcast_items row per clip. The guide counts forward from that row
to work out what is on air at any moment.

Usage:

    .venv/bin/python app/start_broadcast.py

Called by scripts/playout.sh just before FFmpeg starts.
"""

import os
import re
import subprocess
import sys
from pathlib import Path

import psycopg

# Locate the project from this file, ROOT gives the project root,
# and PLAYLIST gives the path to the playlist file.
ROOT = Path(__file__).resolve().parent.parent
PLAYLIST = ROOT / "stream" / "playlist.txt"

DSN = os.environ.get("DATABASE_URL", "dbname=tvchannel")

# Folder name -> the playlist already sorts clips into media/programs, 
# media/idents and media/ads, so nothing extra is needed when the footage changes.
KINDS = {"programs": "program", "idents": "ident", "ads": "ad"}


def fail(msg):
    """Stop with a message on stderr and a non-zero exit code."""
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


# ---------------------------------------------------------------------------
# Reading the playlist
# ---------------------------------------------------------------------------
def read_playlist():
    """Pull the clip paths out of FFmpeg's concat format, in order."""
    if not PLAYLIST.is_file():
        fail(f"no playlist at {PLAYLIST}. Run ./scripts/make-playlist.sh first.")

    paths = []
    for line in PLAYLIST.read_text().splitlines():
        line = line.strip()

        # Skip blanks and comments. Only "file '...'" lines name a clip.
        if not line.startswith("file "):
            continue

        # Drop the "file " prefix, then the single quotes the concat demuxer
        # requires around the path.
        paths.append(Path(line[5:].strip().strip("'")))

    if not paths:
        fail(f"{PLAYLIST} has no clips in it.")

    return paths


# ---------------------------------------------------------------------------
# Describing one clip
# ---------------------------------------------------------------------------
def title_from(path):
    """01-morning-show.mp4 -> "Morning Show"."""
    stem = re.sub(r"^\d+[-_]", "", path.stem)      # drop the ordering prefix
    return stem.replace("-", " ").replace("_", " ").title()


def kind_from(path):
    """media/ads/ad-01.mp4 -> "ad". Unknown folders count as programmes."""
    return KINDS.get(path.parent.name, "program")


def duration_of(path):
    """Seconds of video, extracted from ffprobe."""
    try:
        out = subprocess.run(
            ["ffprobe", "-v", "error",
             "-show_entries", "format=duration",
             "-of", "csv=p=0", str(path)],
            capture_output=True, text=True, check=True,
        )
        return float(out.stdout.strip())
    except FileNotFoundError:
        fail("ffprobe not found. Is FFmpeg installed?")
    except (subprocess.CalledProcessError, ValueError):
        fail(f"could not read a duration from {path}")


def build_items(paths):
    """Turn the clip list into rows, each carrying its offset into the loop."""
    items = []
    offset = 0.0

    for position, path in enumerate(paths):
        duration = duration_of(path)
        items.append({
            "position": position,
            "title": title_from(path),
            "filename": path.name,
            "kind": kind_from(path),
            "offset_s": offset,
            "duration_s": duration,
        })
        # The next clip starts where this one ends.
        offset += duration

    # Once the last clip finishes the loop restarts, so the running total is
    # also the length of one full cycle.
    return items, offset


# ---------------------------------------------------------------------------
# Writing to Postgres
# ---------------------------------------------------------------------------
def record(items, cycle_s):
    """Insert the broadcast and its items as one transaction."""
    with psycopg.connect(DSN) as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO broadcasts (cycle_s, item_count)
                VALUES (%s, %s)
                RETURNING id
                """,
                (cycle_s, len(items)),
            )
            broadcast_id = cur.fetchone()[0]

            for item in items:
                cur.execute(
                    """
                    INSERT INTO broadcast_items
                        (broadcast_id, position, title, filename,
                         kind, offset_s, duration_s)
                    VALUES (%s, %s, %s, %s, %s, %s, %s)
                    """,
                    (
                        broadcast_id,
                        item["position"],
                        item["title"],
                        item["filename"],
                        item["kind"],
                        item["offset_s"],
                        item["duration_s"],
                    ),
                )
    # Leaving the `with` block commits. Any exception above rolls the whole
    # thing back, so a half-written running order doesn't reach the guide.
    return broadcast_id


def main():
    paths = read_playlist()
    items, cycle_s = build_items(paths)

    try:
        broadcast_id = record(items, cycle_s)
    except psycopg.Error as e:
        fail(f"could not write to the database: {e}")

    print(f"broadcast {broadcast_id}: "
          f"{len(items)} items, {cycle_s:.0f}s per cycle")
    for item in items:
        print(f"  {item['position']:>2}  {item['offset_s']:>7.1f}s  "
              f"{item['kind']:<8} {item['title']}")


if __name__ == "__main__":
    main()
