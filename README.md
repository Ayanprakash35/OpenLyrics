# OpenLyrics

Word-by-word synced lyrics for whatever you're playing in **Apple Music** or **Spotify** — floating
over your desktop, and on your Mac's **lock screen**.

### [⬇ Download OpenLyrics for Mac](https://github.com/Ayanprakash35/OpenLyrics/releases/latest/download/OpenLyrics.dmg)

![The desktop overlay: a line of lyrics filling word by word in the album's color](docs/images/desktop.png)

![The lock-screen overlay: the track name above, the current line large, the next line below](docs/images/lockscreen.png)

OpenLyrics is an open recreation of the idea behind Verci: it watches what's playing, finds
time-synced lyrics, and paints each word as it's sung, tinted with the album artwork's colors. It
lives in the menu bar, never takes clicks away from what's underneath, and needs no account.

The now-playing detection and album-color extraction come from
[Open Glow](https://github.com/Ayanprakash35/Open-glow).

## Features

- **Word-by-word fill.** Each word lights up as it's sung, with a soft edge, a slight lift and a
  glow. Lyrics with per-word timing are followed exactly; line-timed lyrics are spread over the
  line at a natural singing pace.
- **On the lock screen.** Lyrics keep going after you lock your Mac, with the track name above
  them, and the display stays awake while they show (optional).
- **Album colors.** The highlight takes the most vivid color from the cover art; or plain white.
- **Next line preview** underneath, and three dots counting down through instrumental breaks.
- **Two lyrics sources, asked at once:** [LRCLIB](https://lrclib.net) (open, line-synced) and
  NetEase Cloud Music (large catalog, often word-synced). The best match wins — by title, artist
  and track length — and every answer is cached, so replays work offline.
- **Timing nudges** (`⌘]` / `⌘[` in the menu) for lyrics that run early or late.
- **Out of the way:** click-through, on every Space, alongside full-screen apps, hidden while
  paused, nothing in the Dock.

## Requirements

- macOS 14 Sonoma or later (developed on macOS 26)
- Apple Music or Spotify (the desktop app)

## Install

**1. Download** — [**OpenLyrics.dmg**](https://github.com/Ayanprakash35/OpenLyrics/releases/latest/download/OpenLyrics.dmg)

**2. Install** — open the downloaded file and drag **OpenLyrics** onto **Applications**.

**3. Approve it (first time only)** — OpenLyrics isn't from the App Store, so macOS blocks it the
first time:

- Open **OpenLyrics** from Applications. macOS says *"OpenLyrics" Not Opened* — click **Done**.
- Open **System Settings › Privacy & Security** and scroll down to **Security**.
- Next to *"OpenLyrics" was blocked*, click **Open Anyway**, then **Open Anyway** again.

**4. Allow access to your player** — play a song. macOS asks whether OpenLyrics may access Music
(or Spotify): click **OK**. OpenLyrics only reads the track, its position and its artwork; it never
controls playback.

<details>
<summary>Comfortable with Terminal? Step 3 in one line</summary>

```bash
xattr -dr com.apple.quarantine /Applications/OpenLyrics.app
```

</details>

**Updating:** download the new version and replace the app in Applications. Older versions are on
the [Releases](https://github.com/Ayanprakash35/OpenLyrics/releases) page.

### Build it yourself

```bash
git clone https://github.com/Ayanprakash35/OpenLyrics.git
cd OpenLyrics
./Scripts/setup_signing.sh      # once: a local signing identity, so macOS remembers permissions
./Scripts/build_app.sh          # builds and signs build/OpenLyrics.app
open build/OpenLyrics.app
./Scripts/test.sh               # the test suite
```

Works with the Command Line Tools alone; Xcode isn't needed.

## Using OpenLyrics

Everything is in the menu-bar menu (the speech-bubble icon):

| Item | What it does |
| --- | --- |
| Track, artist and status | What's playing and where its lyrics came from |
| Show on Desktop / Lock Screen | Where lyrics appear |
| Position | Top, center or bottom of the screen (desktop) |
| Text Size | Small, Medium, Large, Huge |
| Colors | Album artwork, or white |
| Show Next Line | The upcoming line, smaller, underneath |
| Keep Display Awake on Lock Screen | Stops the locked screen from going dark mid-song |
| Timing | Show lyrics sooner (`⌘]`) or later (`⌘[`) in quarter seconds |
| Reload Lyrics (`⌘R`) | Look the song up again, skipping the cache |
| Preview Lock-Screen Layout | Shows the lock-screen look on the desktop for a few seconds |
| Lyrics Sources / Players | Turn LRCLIB, NetEase, Music or Spotify off |
| Open at Login | Start with your Mac |

## Troubleshooting

**No lyrics appear.** Check the status line in the menu:

- *No access to Music/Spotify* — open **System Settings › Privacy & Security › Automation**, turn
  on your player under OpenLyrics, then choose **Try Again**.
- *No lyrics found* — neither source has synced lyrics for this recording. Live and alternate
  versions often don't.
- *Couldn't reach any lyrics service* — OpenLyrics retries every 30 seconds. Some networks block
  `lrclib.net`; NetEase usually still works.

**Lyrics run early or late.** Use **Timing › Show Lyrics Sooner / Later**. The offset stays until
you reset it.

**Nothing on the lock screen.** Lock-screen display uses a private macOS window-server feature; if
a macOS update removes it, the menu says *Show on Lock Screen (unavailable)* and the desktop overlay
keeps working. If lyrics don't appear above the lock screen on your Mac, try a higher level and
relaunch:

```bash
defaults write com.openlyrics.app lockScreenSpaceLevel -int 500
```

(`defaults delete com.openlyrics.app lockScreenSpaceLevel` goes back to the default.)

**Check the lyrics sources from Terminal** — prints what each source finds, never the lyrics:

```bash
/Applications/OpenLyrics.app/Contents/MacOS/OpenLyrics --lookup "Song Title" "Artist" 215
```

**Watch the log:**

```bash
log stream --level info --predicate 'subsystem == "com.openlyrics.app"'
```

## How it works

1. **What's playing.** Music and Spotify post a notification whenever playback changes;
   OpenLyrics listens, and asks the player over AppleScript for the track, its artwork, and — every
   1¼ seconds while playing — the playback position and track length. A clock carries the position
   forward smoothly between samples, so the fill moves at 60 fps rather than jumping each second;
   small disagreements are eased out and seeks snap.
2. **Finding lyrics.** LRCLIB and NetEase are asked in parallel. Search results are matched to the
   track by title (with "Remastered", "Radio Edit", "feat." and similar removed), artist and
   length — recordings more than 12 seconds apart are rejected, since their timing wouldn't line
   up. NetEase's word-timed format is used when available; otherwise LRC line timing, with each
   word's timing estimated from its length.
3. **Drawing.** A borderless, transparent, click-through window per surface hosts a SwiftUI view
   that picks the current line every frame. Each word is a dim copy with a highlight copy on top,
   masked by a gradient that moves across the word as it's sung.
4. **The lock screen.** macOS has no public way to draw over the lock screen. Its window server,
   SkyLight, stacks *spaces* by an absolute level, and the lock screen sits at level 300.
   OpenLyrics creates its own space at level 400 — where macOS shows notifications over the lock
   screen — and moves its lock-screen window onto it. The SkyLight calls are looked up at runtime,
   so if they ever disappear the app carries on without the lock-screen feature.

## Privacy

OpenLyrics sends the track's title, artist, album and length to the lyrics sources you have turned
on, and nothing else. No accounts, analytics or tracking. Lyrics are cached in
`~/Library/Caches/com.openlyrics.app` (menu › Clear Lyrics Cache empties it).

## License

MIT — see [LICENSE](LICENSE). Lyrics belong to their rights holders; OpenLyrics fetches them at
playback time for personal display and doesn't redistribute them.
