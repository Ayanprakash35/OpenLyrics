# Changelog

## 0.2.0 — 2026-10-27

- **Kinetic styles, after Verci.** *Stack*: a word wall that drifts in 3D — the word being sung in
  a highlight box at the bottom, filling as it's sung, springing up into a big middle slot when the
  next word starts while older words dim and drift away. *Lens*: the song's words on a curved
  column, the sung word rolling to the middle, closest to the glass. The previous look stays as
  *Lines*.
- **Word icons**: over 260 lyric words (and their plural, -ing and -ed forms) get an animated SF
  Symbol beside them.
- **Three colors from the album** (lyric text, highlight, secondary text), or custom ones.
- **React to the Music** (opt-in): words and icons swell on the beat, using Open Glow's audio
  analysis.
- **Display** picker for which screen the lyrics show on.
- Hidden overlays no longer draw: an overlay that was turned off or waiting for the lock screen
  kept rendering 60 frames a second in the background (about 40% CPU).
- Visible overlays draw at 60 fps only around word changes and 30 fps otherwise, and lay words out
  once instead of every frame: about 12% CPU for the Stack style instead of 35–45%.

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
