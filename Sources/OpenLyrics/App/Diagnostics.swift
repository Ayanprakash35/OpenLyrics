import AppKit
import SwiftUI


/// Command-line helpers for checking OpenLyrics without a player, run from the app bundle:
///
///     OpenLyrics.app/Contents/MacOS/OpenLyrics --lookup "Title" "Artist" [seconds]
///         Asks every lyrics source and prints what each found (kind, line count, timing),
///         never the lyrics themselves. Skips the cache.
///     OpenLyrics.app/Contents/MacOS/OpenLyrics --demo
///         Runs the app with built-in demo lyrics instead of following a player.
enum Diagnostics {
    static var isDemo: Bool { CommandLine.arguments.contains("--demo") }
    /// `--offscreen`: overlay windows are placed far off every screen, so rendering can be measured
    /// live without anything appearing.
    static var isOffscreen: Bool { CommandLine.arguments.contains("--offscreen") }

    /// Runs `--lookup` and exits, if that's what was asked for.
    static func runLookupIfRequested() {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--lookup"), arguments.count > flag + 2 else { return }
        let query = TrackQuery(
            title: arguments[flag + 1],
            artist: arguments[flag + 2],
            album: "",
            duration: arguments.count > flag + 3 ? Double(arguments[flag + 3]) : nil
        )
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            print("Looking up \"\(query.searchTitle)\" by \(query.searchArtist), length \(query.duration.map { "\($0) s" } ?? "unknown")")
            for provider in [LRCLibProvider(), NetEaseProvider()] as [any LyricsProvider] {
                do {
                    let match = try await provider.lyrics(for: query)
                    print("  \(provider.id.displayName): \(describe(match))")
                } catch {
                    print("  \(provider.id.displayName): \(error)")
                }
            }
            let result = await LyricsService(cache: nil).lookup(query, using: Set(LyricsProviderID.allCases))
            switch result {
            case .found(let lyrics): print("Chosen: \(lyrics.kind.rawValue) from \(lyrics.source)")
            case .notFound: print("Chosen: none (not found)")
            case .unavailable: print("Chosen: none (no source reachable)")
            }
            semaphore.signal()
        }
        semaphore.wait()
        exit(0)
    }

    /// Runs `--snapshot <directory>` and exits, if asked: renders the overlay with the demo lyrics
    /// at a few moments, on the desktop and lock-screen layouts, into PNGs over a sample backdrop.
    /// (Offscreen rendering can't draw the desktop's frosted backdrop; a dark tint stands in.)
    @MainActor
    static func runSnapshotIfRequested() {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--snapshot"), arguments.count > flag + 1 else { return }
        let directory = URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func save<V: View>(_ view: V, width: CGFloat, height: CGFloat, name: String) {
            let framed = ZStack {
                LinearGradient(colors: [Color(red: 0.07, green: 0.06, blue: 0.1), Color(red: 0.16, green: 0.1, blue: 0.16)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                view
            }
            .frame(width: width, height: height)
            let renderer = ImageRenderer(content: framed)
            renderer.scale = 2
            guard let image = renderer.cgImage else { return }
            let file = directory.appending(path: "\(name).png")
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: file)
            print(file.path)
        }
        var colors = LyricColors.fromArtwork(accents: demoAccents)
        // `--gradient` renders the blended style; otherwise each word gets its own color.
        colors.perWord = !CommandLine.arguments.contains("--gradient")
        let stackBase = Settings.TextSize.medium.pointSize * 2.2
        let lensBase = Settings.TextSize.medium.pointSize * 1.9
        let entries = LensLayout.entries(in: demoLyrics)
        let starts = entries.map(\.word.start)
        for time in [1.12, 1.45, 2.3, 3.5, 5.15, 9.3, 10.4, 11.5] {
            let words = StackLayout.words(in: demoLyrics, at: time, icons: true)
            save(KineticWordsView(words: words, colors: colors, baseSize: stackBase, time: time, beat: .none, drift: true),
                 width: 1000, height: 440, name: String(format: "stack-%05.2f", time))
        }
        let card = VStack(spacing: 0) {
            NowPlayingCard(title: "Word by Word", subtitle: "OpenLyrics Demo", status: "Word by word · NetEase",
                           tone: .good, artwork: nil, accent: colors.highlight.color)
            NowPlayingCard(title: "Nothing playing", subtitle: "Open Music or Spotify", status: "Waiting for a player",
                           tone: .quiet, artwork: nil, accent: colors.highlight.color)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, .dark)
        save(card, width: 290, height: 140, name: "menu-card")
        for time in [2.3, 6.2, 13.6] {
            let words = LensLayout.words(in: entries, starts: starts, at: time, icons: true)
            save(KineticWordsView(words: words, colors: colors, baseSize: lensBase, time: time, beat: .none, drift: false),
                 width: 1000, height: 520, name: String(format: "lens-%05.2f", time))
        }
        // The effects, on lyrics written to set them off, under a title with an easter egg.
        let script = SceneDirector.script(for: sceneLyrics, track: .init(title: "Viva la Vida", artist: "OpenLyrics Demo"))
        let constellations = Dictionary(uniqueKeysWithValues: script.events.filter { $0.kind == .constellation }
            .map { ($0.start, ConstellationLayout.nodes(for: $0, in: sceneLyrics)) })
        for time in [2.6, 6.6, 7.4, 10.2, 12.6, 15.4, 18.8, 22.4] {
            let events = script.active(at: time)
            let constellation = events.first { $0.kind == .constellation }
            let takeover = constellation?.envelope(at: time) ?? 0
            let view = ZStack {
                KineticWordsView(words: ConstellationLayout.handoff(takeover).words > 0 ? StackLayout.words(in: sceneLyrics, at: time, icons: true) : [],
                                 colors: colors, baseSize: stackBase, time: time, beat: .none, drift: true)
                    .opacity(ConstellationLayout.handoff(takeover).words)
                if let constellation, let stars = constellations[constellation.start] {
                    ConstellationView(frame: ConstellationLayout.frame(nodes: stars, at: time), colors: colors,
                                      baseSize: stackBase, time: time, beat: .none)
                        .frame(width: stackBase * 16, height: stackBase * 6)
                        .opacity(ConstellationLayout.handoff(takeover).stars)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: stackBase * 3.8)
            .modifier(SceneLayers(events: events, time: time, baseSize: stackBase, colors: colors))
            save(view, width: 1300, height: 560, name: String(format: "scene-%05.2f", time))
        }
        exit(0)
    }

    /// Runs `--benchmark` and exits, if asked: renders two seconds of the Stack and Lens styles
    /// offscreen at 60 fps and prints the time per frame, to compare rendering changes.
    @MainActor
    static func runBenchmarkIfRequested() {
        guard CommandLine.arguments.contains("--benchmark") else { return }
        let colors = LyricColors.fromArtwork(accents: demoAccents)
        let entries = LensLayout.entries(in: demoLyrics)
        let starts = entries.map(\.word.start)
        // "stack + rain" adds the heaviest effect, a whole song of rain.
        let rain = [SceneEvent(kind: .rain, start: 0, end: 60, seed: 7)]
        for style in ["stack", "lens", "stack + rain"] {
            let clock = ContinuousClock()
            let began = clock.now
            let frames = 120
            for frame in 0..<frames {
                let time = 1.0 + Double(frame) / 60
                let words = style == "lens"
                    ? LensLayout.words(in: entries, starts: starts, at: time, icons: true)
                    : StackLayout.words(in: demoLyrics, at: time, icons: true)
                let view = KineticWordsView(words: words, colors: colors, baseSize: 75, time: time, beat: .none, drift: style != "lens")
                    .frame(width: 1200, height: 400)
                    .modifier(SceneLayers(events: style.hasSuffix("rain") ? rain : [], time: time, baseSize: 75, colors: colors))
                _ = ImageRenderer(content: view).cgImage
            }
            let perFrame = (clock.now - began) / frames
            print("\(style): \(perFrame.formatted(.units(allowed: [.milliseconds], fractionalPart: .show(length: 2)))) per frame")
        }
        exit(0)
    }

    private static func describe(_ match: ProviderMatch?) -> String {
        guard let match else { return "nothing" }
        let lyrics = match.lyrics
        let sung = lyrics.lines.filter { !$0.isGap }
        let span = sung.first.map { first in "\(format(first.start))–\(format(sung.last?.end ?? first.end))" } ?? "-"
        let words = sung.flatMap(\.words)
        let withIcons = words.filter { WordIcons.icon(for: $0.text) != nil }.count
        let iconShare = words.isEmpty ? 0 : 100 * withIcons / words.count
        return "\(lyrics.kind.rawValue), \(sung.count) lines, \(words.count) words (\(iconShare)% with icons, \(script(of: words))), "
            + "\(span), confidence \(String(format: "%.2f", match.confidence))"
    }

    /// The writing system most of the words' letters belong to.
    private static func script(of words: [LyricWord]) -> String {
        var counts: [String: Int] = [:]
        for scalar in words.flatMap({ $0.text.unicodeScalars }) where CharacterSet.letters.contains(scalar) {
            let name: String = switch scalar.value {
            case 0x0900...0x097F: "Devanagari"
            case 0x0A00...0x0A7F: "Gurmukhi"
            case 0x0B80...0x0BFF: "Tamil"
            case 0x0C00...0x0C7F: "Telugu"
            case 0x0600...0x06FF: "Arabic"
            case 0x3040...0x30FF: "Japanese kana"
            case 0x4E00...0x9FFF: "Han"
            case 0xAC00...0xD7AF: "Hangul"
            case 0x0400...0x04FF: "Cyrillic"
            default: scalar.value < 0x0250 ? "Latin" : "other"
            }
            counts[name, default: 0] += 1
        }
        return counts.max { $0.value < $1.value }?.key ?? "no letters"
    }

    private static func format(_ seconds: TimeInterval) -> String {
        String(format: "%d:%04.1f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
    }

    /// Lyrics written for the demo (not from any song), word-timed so every effect shows.
    static let demoLyrics: Lyrics = {
        let lines: [(TimeInterval, String)] = [
            (1.0, "Every word lights up the moment it is sung"),
            (5.0, "Colors borrowed from the cover on the screen"),
            (9.0, "Angels floating by you, never in your way"),
            (13.0, "Even on the lock screen while the music plays"),
            (17.5, ""),
            (23.0, "OpenLyrics, word by word"),
        ]
        var raw: [LyricLine] = []
        for (index, (start, text)) in lines.enumerated() {
            let end = index + 1 < lines.count ? lines[index + 1].0 : start + 4
            let words = WordTiming.estimate(WordTiming.tokenize(text), start: start, end: end)
            raw.append(LyricLine(start: start, end: end, words: words, hasWordTiming: !words.isEmpty))
        }
        return Lyrics.synced(lines: raw, source: "OpenLyrics demo", duration: 28)!
    }()

    /// Lyrics written to set off the effects (not from any song): rain, a car, a bridge that
    /// becomes a constellation, and a flag under the right title.
    static let sceneLyrics: Lyrics = {
        let lines: [(TimeInterval, String)] = [
            (1.0, "Rain keeps tapping on the window pane"),
            (5.0, "Rolling in a Cadillac across the town"),
            (9.0, "Meet me on the bridge above the river"),
            (12.0, "Every word we said becomes a light"),
            (15.0, "Lines between them drawing out the way"),
            (18.0, "Holding on until the morning comes"),
            (21.0, "Viva the summer, viva the sound"),
        ]
        var raw: [LyricLine] = []
        for (index, (start, text)) in lines.enumerated() {
            let end = index + 1 < lines.count ? lines[index + 1].0 : start + 4
            let words = WordTiming.estimate(WordTiming.tokenize(text), start: start, end: end)
            raw.append(LyricLine(start: start, end: end, words: words, hasWordTiming: !words.isEmpty))
        }
        return Lyrics.synced(lines: raw, source: "OpenLyrics demo", duration: 26)!
    }()

    static let demoDuration: TimeInterval = 28
    static let demoTrack = NowPlayingMonitor.Track(player: .music, id: "demo", title: "Word by Word", artist: "OpenLyrics Demo", album: "")
    /// A green and blue cover, the kind of artwork the gradients are made for.
    static let demoAccents = [
        PaletteColor(red: 0.42, green: 0.92, blue: 0.55),
        PaletteColor(red: 0.30, green: 0.62, blue: 1.0),
        PaletteColor(red: 0.20, green: 0.80, blue: 0.82),
    ]
    static let demoPalette = ArtworkPalette(primary: demoAccents[0], secondary: demoAccents[1], balance: 0.6)
}
