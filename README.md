# Personal TV Channel + Latency Lab

A self-running linear television channel, built from scratch on macOS, plus an investigation into
end-to-end streaming latency.

> **This is a lab / test environment.**

Not video-on-demand. A **linear channel**: it plays continuously on a schedule whether or not anyone
is watching. Tune in at 8:47pm and you get whatever is playing at 8:47pm, mid-scene. No pause, no
rewind, no catch-up.

## Status

Work in progress.

## Stack

| Layer | Tool |
|---|---|
| Video engine | FFmpeg (`ffmpeg-full` — needs `libsrt` and `libfreetype`) |
| Delivery | HLS, low-latency HLS, SRT |
| Application | Python — scheduler, playout loop, guide API |
| Storage | PostgreSQL — schedule, program guide, latency measurements |
| Viewer | HTML/JS + hls.js |
| Serving | nginx |

## Layout

```
media/          source video (gitignored)
  programs/     the shows
  idents/       channel stings
  ads/          fake commercial breaks
scripts/        bash glue — media prep, playout
stream/         live HLS output (gitignored, regenerated constantly)
web/            viewer page and program guide
```

## Note

Homebrew's default `ffmpeg` formula was slimmed down and **omits both `libsrt` and `libfreetype`** —
which removes SRT output and the `drawtext` filter. Use `ffmpeg-full`.