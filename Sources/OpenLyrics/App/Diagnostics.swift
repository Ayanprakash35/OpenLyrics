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
        let colors = LyricColors.fromArtwork(demoPalette)
        let stackBase = Settings.TextSize.medium.pointSize * 2.2
        let lensBase = Settings.TextSize.medium.pointSize * 1.9
        let entries = LensLayout.entries(in: demoLyrics)
        let starts = entries.map(\.word.start)
        for time in [1.12, 1.45, 2.3, 3.5, 5.15, 9.3, 10.4, 11.5] {
            let words = StackLayout.words(in: demoLyrics, at: time, icons: true)
            save(KineticWordsView(words: words, colors: colors, baseSize: stackBase, time: time, beat: 0, drift: true),
                 width: 1000, height: 440, name: String(format: "stack-%05.2f", time))
        }
        for time in [2.3, 6.2, 13.6] {
            let words = LensLayout.words(in: entries, starts: starts, at: time, icons: true)
            save(KineticWordsView(words: words, colors: colors, baseSize: lensBase, time: time, beat: 0, drift: false),
                 width: 1000, height: 520, name: String(format: "lens-%05.2f", time))
        }
        exit(0)
    }

    /// Runs `--benchmark` and exits, if asked: renders two seconds of the Stack and Lens styles
    /// offscreen at 60 fps and prints the time per frame, to compare rendering changes.
    @MainActor
    static func runBenchmarkIfRequested() {
        guard CommandLine.arguments.contains("--benchmark") else { return }
        let colors = LyricColors.fromArtwork(demoPalette)
        let entries = LensLayout.entries(in: demoLyrics)
        let starts = entries.map(\.word.start)
        for style in ["stack", "lens"] {
            let clock = ContinuousClock()
            let began = clock.now
            let frames = 120
            for frame in 0..<frames {
                let time = 1.0 + Double(frame) / 60
                let words = style == "stack"
                    ? StackLayout.words(in: demoLyrics, at: time, icons: true)
                    : LensLayout.words(in: entries, starts: starts, at: time, icons: true)
                let view = KineticWordsView(words: words, colors: colors, baseSize: 75, time: time, beat: 0, drift: style == "stack")
                    .frame(width: 1200, height: 400)
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
        return "\(lyrics.kind.rawValue), \(sung.count) lines, \(words.count) words (\(iconShare)% with icons), "
            + "\(span), confidence \(String(format: "%.2f", match.confidence))"
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

    static let demoDuration: TimeInterval = 28
    static let demoTrack = NowPlayingMonitor.Track(player: .music, id: "demo", title: "Word by Word", artist: "OpenLyrics Demo", album: "")
    static let demoPalette = ArtworkPalette(
        primary: PaletteColor(red: 1.0, green: 0.62, blue: 0.38),
        secondary: PaletteColor(red: 1.0, green: 0.38, blue: 0.55),
        balance: 0.6
    )
}
