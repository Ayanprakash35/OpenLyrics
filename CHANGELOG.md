# Changelog

## 0.4.0 — 2026-10-27

- **Apple Music no longer stalls when you lock or unlock.** React to the Music used to listen
  through ScreenCaptureKit, which macOS counts as recording the screen, and Apple Music re-checks
  its copy protection — pausing for a moment — every time a screen recording stops (at lock) and
  starts (at unlock). It now listens through a Core Audio process tap, which isn't a screen
  recording, on macOS 14.2 and later. macOS asks once for System Audio Recording access.
- **Lyrics were not showing.** In 0.2.0 and later, a hidden overlay drew nothing, and SwiftUI then
  shrank its window to nothing; showing it again restored the window but not the view inside, so
  lyrics could stay invisible. The overlay windows now always keep their screen's size.
- **Each Word Its Own Color** (new default): every word's box, text and icon takes the next of the
  cover's colors. **Blend Colors Within Words** keeps the gradients. Both in Colors.
- **Redesigned menu**: a now-playing card with the album cover, title, artist and a status dot;
  settings grouped under Look, Where and Lyrics, each with an icon; color swatches showing the
  album colors.
- README, contributing guide, issue and pull-request templates, and room for demo videos and
  screenshots (`docs/media`).

## 0.3.0 — 2026-10-27

- **Gradients from the album cover.** Up to four distinct colors are read from the artwork (they
  used to be two, and only one was used). Lyric text runs from a tint of the leading color to one
  of the second, the highlight box from the second to the leading one, and secondary text is a
  deep shade of the third — a green and blue cover gives green-to-blue words in a blue-to-green
  box. Icons take the highlight gradient. One-color covers get neighboring shades; custom colors
  get gentle gradients of their own.
- **Bounce to the Beat** (on by default): each sung word gives the words a small swell and a hop,
  icons a touch more, the box a hint of brightness; a line's first word and held notes hit a
  little harder. No permission needed — it follows the lyrics' timing. With React to the Music on,
  the audio beat adds in.
- **Track name** on the lock screen is now small, faint and in spaced capitals — and off unless
  you turn on Show Track Name on Lock Screen.

## 0.2.1 — 2026-10-27

- **Four times the word icons**: over 1,000 words (from 266), now including the words songs use
  most — you, me, we, tell, call, wait, need, see, start, life, good, beautiful, numbers — plus
  animals, food, places and more. A typical song now has an icon on 25–40% of its words.
- **Emoji** for things SF Symbols doesn't draw (angels, ghosts, roses, pizza, rockets, diamonds…),
  shown in their own colors.
- Two-letter words (me, we, us, up, go, no) can have icons; endings are never stripped down to two
  letters, so "uses" doesn't match "us".

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
