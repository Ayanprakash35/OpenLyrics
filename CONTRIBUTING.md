# Contributing to OpenLyrics

Thanks for wanting to help! OpenLyrics is a small, dependency-free macOS app, and a few rules keep
it that way.

## Setup

- macOS 14 or later (developed on macOS 26, Apple silicon).
- Swift 6: Xcode, or just the Command Line Tools (`xcode-select --install`).

```bash
./Scripts/setup_signing.sh   # once: a local signing identity so macOS keeps permissions across rebuilds
./Scripts/build_app.sh       # builds and signs build/OpenLyrics.app
./Scripts/test.sh            # runs the test suite
```

Run the app through `open build/OpenLyrics.app` rather than the binary inside it, so macOS checks
OpenLyrics' own permissions instead of your terminal's.

### Diagnostics

The app binary takes a few flags that make changes easy to check without a player:

| Flag | What it does |
|---|---|
| `--lookup "Title" "Artist" [seconds]` | Asks every lyrics source and prints what each found — kind, line and word counts, share of words with icons — never the lyrics |
| `--snapshot <dir>` | Renders the Stack and Lens styles and the menu card offscreen to PNGs (`--gradient` for blended colors) |
| `--demo` | Runs with built-in demo lyrics instead of following a player |
| `--offscreen` | Puts the overlay windows off every screen, to measure rendering live without showing anything |
| `--benchmark` | Renders two seconds of each style offscreen and prints the time per frame |

## Ground rules

- **No third-party dependencies.** Apple frameworks only.
- **One private API, kept optional.** The lock-screen overlay uses SkyLight calls looked up at
  runtime (`LockScreenSpace`); if they're missing, the app keeps working on the desktop. Don't add
  others without a fallback.
- **Never the microphone.** React to the Music reads the system's sound output through a Core
  Audio process tap (ScreenCaptureKit on macOS before 14.2). No microphone APIs, no
  `NSMicrophoneUsageDescription`.
- **Privacy:** the only data that leaves the Mac is a track's title, artist, album and length,
  sent to the lyrics sources the user has turned on. Keep it that way, and update the README's
  Privacy section with any change.
- **No lyrics in the repository.** Tests, fixtures, demo and screenshots use invented text.

## Code style

- Small files, one responsibility each.
- Tunable constants live in an enum at the top of their file, each with a doc comment giving the
  unit and a sensible range.
- Styles are pure functions of time (`StackLayout`, `LensLayout`, `Beat`): no animation state, so
  any frame can be computed — and tested — on its own.
- Comment what isn't obvious; skip comments that repeat the code.
- Swift 6 strict concurrency, zero warnings.

## Tests

Add or update tests with every change: Swift Testing, in `Tests/OpenLyricsTests`. For anything
visible, also render it with `--snapshot` and try the built app.

## Pull requests

Keep them focused, describe what you changed and how you tested it, and include before/after
images or a short screen recording for visual changes.
