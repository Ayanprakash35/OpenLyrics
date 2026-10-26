# Changelog

## 0.1.1 — 2026-10-26

- Lyrics show about as soon as the fastest source answers (around 1.5 s instead of up to 9 s): a
  word-timed exact match is taken at once, any other synced match after a 1.5 s grace period, and a
  source that couldn't be reached (such as a blocked lrclib.net) sits out for 5 minutes.
- No background behind the lyrics on the desktop.
- The overlay windows put their frame back if macOS resized them (the lock-screen window could
  come out taller than the screen, pushing the lyrics off center).

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
