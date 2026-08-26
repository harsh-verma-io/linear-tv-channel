# Personal TV Channel + Latency Lab

A self-running linear television channel, built from scratch on macOS with FFmpeg, nginx, Flask, Postgres and hls.js, plus an investigation into end-to-end streaming latency.

> **This is a lab/test environment.**

Not video-on-demand. A **linear channel**: it plays continuously on a schedule whether or not anyone
is watching. Tune in at 8:47 pm, and you will get whatever is playing at 8:47 pm, mid-scene. Pauses, rewinds, and catch-ups are not allowed. 

---

## The channel

<p align="center">
  <img src="docs/viewer.png" width="100%" alt="The webpage: a programme guide beside the stream, with a live latency lab below">
</p>

The screenshot above presents the channel running as anyone who visits the page would see it. The guide on the right knows what is on air, how much is left of it, and what's next, all worked out from the playout loop itself rather than from a hardcoded schedule. Underneath is a live latency lab measuring these factors: how far behind live the stream is, how much video is buffered ahead, how many frames have been dropped, every reading is rendered 4x per second and stored into Postgres each second for stream analysis and logging.

That is the part I like most. The same page is both the television and the
instrument, so every visitor is also a measurement probe. Which is where the
numbers below came from.

---

## The interesting part

During the lab tests, the channel stamps the wall clock onto every frame, then the viewer page measures how far behind real time the picture is and writes the reading to
Postgres. Across fourteen runs and about 8,400 measurements, a few things became clear.

<p align="center">
  <img src="docs/fig1-latency-vs-segment.png" width="39%" valign="top" alt="Latency against segment length">
  <img src="docs/fig5-soak-hour.png" width="59%" valign="top" alt="One hour of continuous operation">
</p>

**Latency is a fixed multiple of segment length.** Roughly 3.5x, and that
number decomposes into three segments of player hold-back plus half a segment
of encoder write delay. Segment length multiplies everything rather than adding
to it, so halving it halves the delay.

**Almost none of the delay is the network.** Extrapolating that line back to
zero puts the fixed cost of encoding, sending and decoding at under a second.
HLS is slow because it chops video into files and a file can't be sent until
it's finished. The same encoder pushing SRT arrives in about 2 seconds against
HLS's 20.

**There are two ways to cut latency and they break differently.** Shortening
segments keeps a healthy buffer but makes the latency wander by several
seconds. Tightening the player's hold-back holds latency to a hundredth of a
second until the buffer runs dry and the picture freezes. One is unsteady but
unbreakable, the other is precise but brittle.

**Squeezing bandwidth costs stability and startup, not latency.** Every capped
run sat within a second of the uncapped ones, but time to first frame went from
0.45 seconds to over three, and the latency wobble grew sixtyfold.

**It holds.** An hour of unattended playback moved the latency by 8
milliseconds, with no stalls and no gaps in 3,579 readings.

**And it works outside the lab environment.** Since these experimental runs the channel has been watched from New York, Pennsylvania, California, and Delhi, India through a Cloudflare Tunnel, and it behaved the way the numbers predict.

📊 **[Full write-up with all six figures and the methodology →](docs/findings.md)**

Raw data for every run is in [`data/`](data).

---

## How it works

```
media/*.mp4 ──> playout.sh ──> one FFmpeg process ──┬──> HLS segments ──> nginx ──> browser
                    │                               └──> SRT stream ────> ffplay        │
                    │                                                                   │
                    │ writes the running order                posts its latency         │
                    │ and start time, once                    readings, asks the guide  │
                    ▼                                                                   ▼
                 Postgres  <──────────────────────────────────────────────────>  Flask API
                    │
                    └──> chart.py
```

One FFmpeg process reads a concat playlist, loops forever, burns the wall clock
into the picture, and writes two outputs from a single encode using the `tee`
muxer. Because both outputs carry identical frames and identical timestamps,
any difference between them is transport rather than encoding.

The browser works out its own latency from the `PROGRAM-DATE-TIME` tag in the
HLS manifest, which says what wall-clock moment the video started. Subtract the
current playback position from that and compare against the clock. No stopwatch
and no second camera.

The programme guide relies on arithmetic the same way. Back-end doesn't need to 
communicate with front-end to learn what's on air. playout records the moment the 
brodcast loop began and how long each clip runs, so position in the running order 
comes from elapsed seconds modulo the length of the loop. The page asks about the 
timestamp of the frame it is currently showing rather than the current clock, which 
is what keeps the guide in sync with the frames being displayed to the viewer live.

`scripts/experiment.sh` runs one measured condition end to end: start the
channel, wait for the manifest to fill, launch an isolated browser with timer
throttling disabled, record for a set duration, shut everything down and print
a summary straight from the database.

---

## Stack

| Layer | Tool |
|---|---|
| Video engine | FFmpeg (`ffmpeg-full`, for `libsrt` and `libfreetype`) |
| Delivery | HLS over HTTP, SRT |
| Serving | nginx |
| API | Flask + psycopg |
| Storage | PostgreSQL |
| Viewer | HTML/JS + hls.js |
| Charts | matplotlib |
| Public access | Cloudflare Tunnel (`cloudflared`) |

---

## Layout

```
app/         latency_log.py        Flask API: records readings, serves the guide
             start_broadcast.py    records the running order when playout starts
             chart.py              reads Postgres, writes the figures
db/          schema.sql            runs and samples, broadcasts and broadcast_items
scripts/     playout.sh            the channel itself, one FFmpeg process
             experiment.sh         runs one measured condition, start to finish
             make-test-clips.sh    generates format-consistent test footage
             make-ident.sh         the channel ident, bars and a four-chord loop
             normalise.sh          converts any footage into the channel format
             make-playlist.sh      builds the running order
nginx/       tv-channel.conf       serves the page, the stream, and proxies the API
web/         index.html            viewer with a programme guide and latency readout
data/        runs.csv              every run and every reading, as recorded
docs/        findings.md           the findings, plus six figures
media/       source video (gitignored)
stream/      live HLS output (gitignored, regenerated constantly)
```

---

## Running it

```bash
brew install ffmpeg-full nginx postgresql@16
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt

createdb tvchannel
psql -d tvchannel -f db/schema.sql
```

Build the media. Drop your own footage into `media/programs` and `media/ads`,
or generate test clips:

```bash
./scripts/make-test-clips.sh     # synthetic footage, skip if using your own
./scripts/make-ident.sh          # the channel ident
./scripts/normalise.sh           # convert everything into the channel format
./scripts/make-playlist.sh       # build the running order
```

Then put it on air:

```bash
.venv/bin/python app/latency_log.py &
./scripts/playout.sh
```

Open `http://localhost:8888`. To share it with someone outside your network:

```bash
cloudflared tunnel --url http://localhost:8888
```

To run a measured experiment instead:

```bash
./scripts/experiment.sh --seg 6 --sync 3 --minutes 10
.venv/bin/python app/chart.py
```

---

## Notes

This is a lab. It runs on one machine over loopback with a single viewer, no
authentication, and Flask's development server. The relationships in the
findings should hold elsewhere but the absolute numbers are produced via my 
personal computer.

Homebrew's default `ffmpeg` formula was slimmed down and omits both `libsrt`
and `libfreetype`, which removes SRT output and the `drawtext` filter that
burns the clock into the picture. `ffmpeg-full` has both.
