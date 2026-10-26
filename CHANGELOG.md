# Changelog

## 0.1.0 — 2026-10-26

First release.

- Word-by-word synced lyrics for Apple Music and Spotify, as a click-through overlay on the
  desktop (top, center or bottom) and on the lock screen.
- Lyrics from LRCLIB and NetEase Cloud Music, asked in parallel; the best match by title, artist
  and length wins, with word-timed lyrics preferred. Results are cached on disk.
- Karaoke fill with a soft edge, a lift and a glow; next-line preview; dots through instrumental
  breaks; highlight color from the album artwork, or white.
- Keeps the display awake while lyrics show on the lock screen.
- Timing nudges in quarter seconds, four text sizes, per-source and per-player switches, open at
  login, lock-screen layout preview.
- `--lookup`, `--demo` and `--snapshot` diagnostics.
