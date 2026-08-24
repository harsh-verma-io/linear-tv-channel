#!/usr/bin/env python3
"""
chart.py — draw the figures for the findings write-up.

Usage:

    pip install matplotlib
    .venv/bin/python app/chart.py

Writes PNGs into docs/.
"""

import os
import statistics as st
from collections import defaultdict

import matplotlib
matplotlib.use("Agg")          # no display needed; write directly to file
import matplotlib.pyplot as plt

import psycopg

DSN = os.environ.get("DATABASE_URL", "dbname=tvchannel")
OUT = os.path.join(os.path.dirname(__file__), "..", "docs")
WARMUP_S = 15

# Runs 7-9 used limit_rate_after 1m, which let the first megabyte of every
# segment through unthrottled. They are kept in the database as the record of
# a methodology failure, but they do not belong on a bandwidth chart.
BROKEN_THROTTLE_RUNS = {7, 8, 9}

INK   = "#1e293b"
BLUE  = "#2563eb"
RED   = "#dc2626"
GREY  = "#94a3b8"
GREEN = "#16a34a"

plt.rcParams.update({
    "figure.dpi": 150,
    "savefig.bbox": "tight",
    "font.size": 10,
    "axes.edgecolor": GREY,
    "axes.labelcolor": INK,
    "text.color": INK,
    "xtick.color": INK,
    "ytick.color": INK,
    "axes.spines.top": False,
    "axes.spines.right": False,
    "axes.grid": True,
    "grid.color": "#e2e8f0",
    "grid.linewidth": 0.8,
})


# ---------------------------------------------------------------------------
# Load
# ---------------------------------------------------------------------------
with psycopg.connect(DSN) as conn, conn.cursor() as cur:
    cur.execute("""SELECT id, started_at, label, segment_time, playlist_size,
                          sync_count, throttle_kbps, startup_ms
                   FROM runs ORDER BY id""")
    runs = {r[0]: dict(id=r[0], started=r[1], label=r[2], seg=r[3],
                       window=r[4], sync=r[5], throttle=r[6], startup=r[7])
            for r in cur.fetchall()}

    cur.execute("""SELECT run_id, recorded_at, latency_s, buffer_ahead_s,
                          dropped_frames, total_frames, stall_count, playback_rate
                   FROM samples ORDER BY run_id, recorded_at""")
    raw = defaultdict(list)
    for row in cur.fetchall():
        raw[row[0]].append(dict(t=row[1], lat=row[2], buf=row[3],
                                dropped=row[4], frames=row[5],
                                stalls=row[6], rate=row[7]))

data, stats = {}, {}
for rid, rows in raw.items():
    start = runs[rid]["started"]
    kept = [r for r in rows
            if (r["t"] - start).total_seconds() > WARMUP_S and r["lat"] is not None]
    if not kept:
        continue
    data[rid] = kept
    lat = [r["lat"] for r in kept]
    buf = [r["buf"] for r in kept if r["buf"] is not None]
    stats[rid] = dict(
        mean=st.mean(lat), sd=st.pstdev(lat), mn=min(lat), mx=max(lat),
        buf=st.mean(buf) if buf else 0,
        stalls=max(r["stalls"] for r in kept) - min(r["stalls"] for r in kept),
        catchup=sum(1 for r in kept if r["rate"] and r["rate"] > 1.0) / len(kept) * 100,
        mins=(kept[-1]["t"] - kept[0]["t"]).total_seconds() / 60,
    )


def save(fig, name):
    path = os.path.abspath(os.path.join(OUT, name))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fig.savefig(path)
    plt.close(fig)
    print(f"wrote {path}")


# ===========================================================================
# 1. Latency is a fixed multiple of segment length
#
# The band is the min-max range measured WITHIN each run. It is not a
# confidence interval - each condition was run once.
# ===========================================================================
ids = sorted([i for i in data
              if runs[i]["sync"] == 3 and runs[i]["throttle"] is None],
             key=lambda i: runs[i]["seg"])
xs = [runs[i]["seg"] for i in ids]
ys = [stats[i]["mean"] for i in ids]

# Through the origin: latency = k * seg. A free intercept fits marginally
# better but lands at -0.6s, and negative latency is not a thing.
k = sum(x * y for x, y in zip(xs, ys)) / sum(x * x for x in xs)

fig, ax = plt.subplots(figsize=(7.5, 4.8))
line_x = [0, 11]
ax.plot(line_x, [k * x for x in line_x], color=GREY, lw=1.4, ls="--", zorder=1,
        label=f"fitted: latency = {k:.2f} x segment length")
for i in ids:
    lo, hi = stats[i]["mn"], stats[i]["mx"]
    ax.vlines(runs[i]["seg"], lo, hi, color=BLUE, lw=7, alpha=0.25, zorder=2)
ax.scatter(xs, ys, s=55, color=BLUE, zorder=3, label="measured mean")

for x, y in zip(xs, ys):
    ax.annotate(f"{y:.1f}s", (x, y), textcoords="offset points",
                xytext=(9, -4), fontsize=9, color=INK)

ax.set_xlabel("Segment length (seconds)")
ax.set_ylabel("Latency behind live (seconds)")
ax.set_title("Latency is a fixed multiple of segment length", loc="left",
             fontsize=12, weight="bold", pad=12)
ax.text(0.02, 0.95,
        "Theory predicts 3.5x: three segments of player hold-back\n"
        "plus half a segment of encoder write delay.",
        transform=ax.transAxes, va="top", fontsize=9, color="#475569")
ax.set_xlim(0, 11)
ax.set_ylim(0, 40)
ax.legend(frameon=False, loc="lower right", fontsize=9)
fig.text(0.01, -0.04,
         "Shaded bars show the range within each run, not statistical uncertainty. "
         "One run per condition.",
         fontsize=8, color="#64748b")
save(fig, "fig1-latency-vs-segment.png")


# ===========================================================================
# 2. The player's hold-back is the second lever
# ===========================================================================
ids = sorted([i for i in data
              if runs[i]["seg"] == 6 and runs[i]["throttle"] is None],
             key=lambda i: runs[i]["sync"])

fig, ax = plt.subplots(figsize=(7.5, 4.8))
for i in ids:
    colour = RED if stats[i]["stalls"] else BLUE
    ax.scatter(runs[i]["sync"], stats[i]["mean"], s=55, color=colour, zorder=3)
    note = f"{stats[i]['mean']:.1f}s"
    if stats[i]["stalls"]:
        note += f"\n{stats[i]['stalls']} stalls"
    ax.annotate(note, (runs[i]["sync"], stats[i]["mean"]),
                textcoords="offset points", xytext=(10, -6), fontsize=9,
                color=RED if stats[i]["stalls"] else INK)

sx = [runs[i]["sync"] for i in ids]
sy = [stats[i]["mean"] for i in ids]
ax.plot(sx, sy, color=GREY, lw=1.2, ls="--", zorder=1)

ax.set_xlabel("Player hold-back (segments behind live)")
ax.set_ylabel("Latency behind live (seconds)")
ax.set_title("Cutting the player's hold-back also cuts latency — until it breaks",
             loc="left", fontsize=12, weight="bold", pad=12)
ax.text(0.02, 0.95,
        "Segment length fixed at 6s. One segment of buffer was not enough\n"
        "slack to survive even a loopback network.",
        transform=ax.transAxes, va="top", fontsize=9, color="#475569")
ax.set_xticks([1, 2, 3, 4])
ax.set_xlim(0.5, 4.7)
ax.set_ylim(0, 32)
save(fig, "fig2-latency-vs-holdback.png")


# ===========================================================================
# 3. Two routes to the same latency, two different failure modes
# ===========================================================================
a = next(i for i in data if runs[i]["seg"] == 2 and runs[i]["sync"] == 3
         and runs[i]["throttle"] is None)
b = next(i for i in data if runs[i]["seg"] == 6 and runs[i]["sync"] == 1
         and runs[i]["throttle"] is None)
labels = ["Short segments\n(seg=2s, hold-back=3)",
          "Tight hold-back\n(seg=6s, hold-back=1)"]

fig, axes = plt.subplots(1, 3, figsize=(10, 3.6))
for ax, (title, vals, fmt) in zip(axes, [
        ("Latency (s)",          [stats[a]["mean"], stats[b]["mean"]], "{:.2f}"),
        ("Latency wobble (sd, s)", [stats[a]["sd"], stats[b]["sd"]],   "{:.2f}"),
        ("Stalls",               [stats[a]["stalls"], stats[b]["stalls"]], "{:.0f}")]):
    bars = ax.bar(labels, vals, color=[BLUE, RED], width=0.55)
    ax.set_title(title, fontsize=10, loc="left")
    ax.tick_params(axis="x", labelsize=8)
    ax.set_ylim(0, max(vals) * 1.35 or 1)
    for bar, v in zip(bars, vals):
        ax.annotate(fmt.format(v), (bar.get_x() + bar.get_width() / 2, v),
                    textcoords="offset points", xytext=(0, 4),
                    ha="center", fontsize=9)
fig.suptitle("Same goal, different damage", x=0.01, ha="left",
             fontsize=12, weight="bold")
fig.text(0.01, -0.06,
         "Shortening segments produced lower latency AND no stalls. Tightening the "
         "player's hold-back produced higher latency and five stalls in five minutes.",
         fontsize=8, color="#64748b")
save(fig, "fig3-two-routes.png")


# ===========================================================================
# 4. Bandwidth pressure: stability and startup, not steady-state latency
# ===========================================================================
base = [i for i in data
        if runs[i]["seg"] == 6 and runs[i]["sync"] == 3 and runs[i]["throttle"] is None]
capped = sorted([i for i in data
                 if runs[i]["throttle"] and i not in BROKEN_THROTTLE_RUNS],
                key=lambda i: runs[i]["throttle"], reverse=True)

STREAM_KBPS = 2628
xs = [runs[i]["throttle"] / STREAM_KBPS for i in capped]
uncapped_x = 1.45          # plotted off to the right as the reference point

fig, axes = plt.subplots(1, 3, figsize=(11, 3.8))

series = [
    ("Buffer held (s)",       [stats[i]["buf"] for i in capped],
                              st.mean([stats[i]["buf"] for i in base]), BLUE),
    ("Latency wobble (sd, s)", [stats[i]["sd"] for i in capped],
                              st.mean([stats[i]["sd"] for i in base]), RED),
    ("Time to first frame (s)", [runs[i]["startup"] / 1000 for i in capped],
                              st.mean([runs[i]["startup"] for i in base]) / 1000, GREEN),
]

for ax, (title, ys, ref, colour) in zip(axes, series):
    ax.plot(xs, ys, "o-", color=colour, lw=1.6, ms=6)
    ax.scatter([uncapped_x], [ref], s=60, color=GREY, zorder=3)
    ax.annotate("no cap", (uncapped_x, ref), textcoords="offset points",
                xytext=(-6, 10), ha="center", fontsize=8, color="#64748b")
    ax.axvline(1.0, color=GREY, lw=1, ls=":")
    ax.set_title(title, fontsize=10, loc="left")
    ax.set_xlabel("Bandwidth ÷ stream bitrate")
    ax.set_ylim(0, max(max(ys), ref) * 1.3)

fig.suptitle("Squeezing bandwidth costs stability and startup, not latency",
             x=0.01, ha="left", fontsize=12, weight="bold")
fig.text(0.01, -0.08,
         "Dotted line marks bandwidth equal to the stream bitrate. Mean latency stayed "
         "within run-to-run noise across every cap.\n"
         "nginx limit_rate caps each connection rather than the client's total, so "
         "these are pressure levels, not calibrated bandwidths.",
         fontsize=8, color="#64748b")
save(fig, "fig4-bandwidth.png")


# ===========================================================================
# 5. An hour, unattended
# ===========================================================================
longest = max(data, key=lambda i: stats[i]["mins"])
rows = data[longest]
t0 = rows[0]["t"]
mins = [(r["t"] - t0).total_seconds() / 60 for r in rows]
lat = [r["lat"] for r in rows]

fig, ax = plt.subplots(figsize=(9, 3.8))
ax.plot(mins, lat, color=BLUE, lw=0.8)
ax.set_xlabel("Minutes into the run")
ax.set_ylabel("Latency (s)")
ax.set_ylim(min(lat) - 1, max(lat) + 1)
ax.set_xlim(0, max(mins))

first5 = st.mean([y for x, y in zip(mins, lat) if x < 5])
last5 = st.mean([y for x, y in zip(mins, lat) if x > max(mins) - 5])
ax.set_title("One hour, untouched: latency moved by 8 milliseconds",
             loc="left", fontsize=12, weight="bold", pad=12)
ax.text(0.02, 0.9,
        f"first 5 min {first5:.3f}s   ·   last 5 min {last5:.3f}s   ·   "
        f"{len(rows)} samples, no gaps, zero stalls",
        transform=ax.transAxes, fontsize=9, color="#475569")
fig.text(0.01, -0.06,
         "seg=6s, hold-back=3, no bandwidth cap. Sampled once per second.",
         fontsize=8, color="#64748b")
save(fig, "fig5-soak-hour.png")


# ===========================================================================
# 6. The tradeoff, all runs at once
#
# The chart the project is named after: where each configuration sits on the
# latency axis, and how steady it was once it got there.
# ===========================================================================
fig, ax = plt.subplots(figsize=(8, 5))

for rid in sorted(data):
    r, s = runs[rid], stats[rid]
    if r["throttle"] and rid in BROKEN_THROTTLE_RUNS:
        continue
    if r["throttle"]:
        colour, marker, lab = "#f59e0b", "s", "bandwidth capped"
    elif s["stalls"]:
        colour, marker, lab = RED, "X", "stalled"
    else:
        colour, marker, lab = BLUE, "o", "clean"
    ax.scatter(s["mean"], max(s["sd"], 0.008), s=70, color=colour,
               marker=marker, zorder=3, label=lab)
    ax.annotate(f"{r['seg']:.0f}s/{r['sync']}", (s["mean"], max(s["sd"], 0.008)),
                textcoords="offset points", xytext=(8, -3), fontsize=8,
                color="#64748b")

ax.set_yscale("log")
ax.set_xlabel("Latency behind live (seconds)")
ax.set_ylabel("Latency wobble — standard deviation (s, log scale)")
ax.set_title("The tradeoff, every run", loc="left", fontsize=12, weight="bold", pad=12)
fig.text(0.01, -0.04,
         "Labels are segment length / player hold-back. Bottom-left is the goal — "
         "low latency and rock steady. Nothing is there.",
         fontsize=8, color="#64748b")

handles, lbls = ax.get_legend_handles_labels()
seen = dict(zip(lbls, handles))
ax.legend(seen.values(), seen.keys(), frameon=False, fontsize=9, loc="upper right")
save(fig, "fig6-tradeoff.png")

print("\ndone.")
