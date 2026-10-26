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
        let moments: [(String, TimeInterval)] = [("mid-line", 3.2), ("next-line", 6.4), ("gap", 20.0)]
        for surface in [OverlaySurface.desktop, .lockScreen] {
            for (name, time) in moments {
                let style = LyricsStyle(
                    fontSize: Settings.TextSize.medium.pointSize * (surface == .lockScreen ? 1.3 : 1),
                    highlight: demoPalette.primary.color, glow: demoPalette.secondary.color,
                    showNextLine: true, backdrop: surface == .desktop, surface: surface
                )
                let view = ZStack {
                    LinearGradient(colors: [Color(red: 0.12, green: 0.14, blue: 0.24), Color(red: 0.35, green: 0.2, blue: 0.3)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    LyricsStage(lyrics: demoLyrics, time: time, style: style,
                                caption: surface == .lockScreen ? "\(demoTrack.title) — \(demoTrack.artist)" : nil)
                }
                .frame(width: 1200, height: surface == .lockScreen ? 420 : 300)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                guard let image = renderer.cgImage else { continue }
                let rep = NSBitmapImageRep(cgImage: image)
                let file = directory.appending(path: "\(surface == .desktop ? "desktop" : "lockscreen")-\(name).png")
                try? rep.representation(using: .png, properties: [:])?.write(to: file)
                print(file.path)
            }
        }
        exit(0)
    }

    private static func describe(_ match: ProviderMatch?) -> String {
        guard let match else { return "nothing" }
        let lyrics = match.lyrics
        let sung = lyrics.lines.filter { !$0.isGap }
        let span = sung.first.map { first in "\(format(first.start))–\(format(sung.last?.end ?? first.end))" } ?? "-"
        return "\(lyrics.kind.rawValue), \(sung.count) lines, \(sung.reduce(0) { $0 + $1.words.count }) words, "
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
            (9.0, "Floating over windows, never in your way"),
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
