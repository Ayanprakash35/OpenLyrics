import Foundation
import Testing
@testable import OpenLyrics

// Lyric text here is invented for the tests.

private func line(_ text: String, start: TimeInterval, step: TimeInterval) -> LyricLine {
    let words = WordTiming.tokenize(text).enumerated().map { index, word in
        LyricWord(text: word.text, start: start + Double(index) * step, end: start + Double(index + 1) * step, spaceAfter: word.spaceAfter)
    }
    return LyricLine(start: start, end: start + Double(words.count) * step, words: words, hasWordTiming: true)
}

private func lyrics(_ lines: [LyricLine]) -> Lyrics {
    Lyrics(kind: .wordSynced, lines: lines, plainText: nil, source: "Test")
}

@Suite("Motion")
struct MotionTests {
    @Test func backOutStartsEndsAndOvershoots() {
        #expect(Motion.backOut(0, duration: 1) == 0)
        #expect(Motion.backOut(1, duration: 1) == 1)
        #expect(Motion.backOut(5, duration: 1) == 1)
        let peak = stride(from: 0.0, through: 1, by: 0.01).map { Motion.backOut($0, duration: 1) }.max() ?? 0
        #expect(peak > 1.05)
        #expect(Motion.backOut(0.5, duration: 1, overshoot: 0) <= 1)
    }

    @Test func advanceCountsStartedWords() {
        let starts: [TimeInterval] = [0, 1, 2, 3]
        let linear = { (t: TimeInterval, d: TimeInterval) in min(t / d, 1) }
        #expect(Motion.advance(starts: starts, at: -1, duration: 0.5, ease: linear) == 0)
        #expect(Motion.advance(starts: starts, at: 0.5, duration: 0.5, ease: linear) == 0)
        #expect(Motion.advance(starts: starts, at: 1.25, duration: 0.5, ease: linear) == 0.5)
        #expect(Motion.advance(starts: starts, at: 2.7, duration: 0.5, ease: linear) == 2)
        #expect(Motion.advance(starts: starts, at: 99, duration: 0.5, ease: linear) == 3)
    }

    @Test func advanceOverlapsFastWords() {
        let starts: [TimeInterval] = [0, 0.1, 0.2]
        let linear = { (t: TimeInterval, d: TimeInterval) in min(t / d, 1) }
        // Both later words are still easing in: 0.25/0.5 + 0.15/0.5.
        #expect(abs(Motion.advance(starts: starts, at: 0.35, duration: 0.5, ease: linear) - 0.8) < 1e-9)
    }

    @Test func curveInterpolatesAndHolds() {
        let points: [(Double, Double)] = [(0, 0), (1, 10), (2, 0)]
        #expect(Motion.curve(-5, points) == 0)
        #expect(Motion.curve(0.5, points) == 5)
        #expect(Motion.curve(1.5, points) == 5)
        #expect(Motion.curve(9, points) == 0)
    }

    @Test func jitterIsStableAndBounded() {
        let values = (0..<500).map { Motion.jitter(UInt64($0)) }
        #expect(values.allSatisfy { (-1...1).contains($0) })
        #expect(Motion.jitter(42) == Motion.jitter(42))
        #expect(Set(values.map { ($0 * 100).rounded() }).count > 50)
    }
}

@Suite("Stack style")
struct StackLayoutTests {
    private let song = lyrics([
        line("paper boats on quiet water", start: 10, step: 1),
        line("lanterns hum", start: 16, step: 1),
    ])

    @Test func nothingBeforeTheFirstLine() {
        #expect(StackLayout.words(in: song, at: 5, icons: false).isEmpty)
    }

    @Test func theFirstWordArrivesBigAndBoxed() throws {
        let words = StackLayout.words(in: song, at: 10.6, icons: false)
        let only = try #require(words.first)
        #expect(words.count == 1)
        #expect(only.text == "paper")
        #expect(only.boxed == 1)
        #expect(only.scale > 0.85)
    }

    @Test func theSungWordIsBoxedBelowTheBigOne() throws {
        // "on" (index 2) is being sung; "boats" just was.
        let words = StackLayout.words(in: song, at: 12.6, icons: false)
        let current = try #require(words.first { $0.text == "on" })
        let previous = try #require(words.first { $0.text == "boats" })
        let older = try #require(words.first { $0.text == "paper" })
        #expect(current.boxed == 1 && previous.boxed == 0)
        #expect(previous.scale > current.scale)
        #expect(older.y < previous.y && previous.y < current.y)
        #expect(older.faded > 0.5)
        #expect(current.fill > 0.5 && current.fill < 0.7)
    }

    @Test func wordsNotYetSungStayHidden() {
        let words = StackLayout.words(in: song, at: 12.6, icons: false)
        #expect(!words.contains { $0.text == "quiet" || $0.text == "water" })
    }

    @Test func oldWordsDriftAway() {
        let words = StackLayout.words(in: song, at: 14.6, icons: false)
        #expect(!words.contains { $0.text == "paper" })
    }

    @Test func aNewLineClearsTheStack() {
        let words = StackLayout.words(in: song, at: 16.8, icons: false)
        #expect(words.map(\.text) == ["lanterns"])
    }

    @Test func iconsAttachWhenAsked() {
        let song = lyrics([line("dance tonight", start: 0, step: 1)])
        #expect(StackLayout.words(in: song, at: 0.5, icons: true).first?.icon?.symbol == "figure.dance")
        #expect(StackLayout.words(in: song, at: 0.5, icons: false).first?.icon == nil)
    }

    @Test func layoutIsTheSameEveryTime() {
        #expect(StackLayout.words(in: song, at: 12.6, icons: true) == StackLayout.words(in: song, at: 12.6, icons: true))
    }
}

@Suite("Lens style")
struct LensLayoutTests {
    private let song = lyrics([
        line("paper boats on quiet water", start: 10, step: 1),
        line("lanterns hum along the bay", start: 16, step: 1),
    ])

    private func words(at time: TimeInterval) -> [PlacedWord] {
        let entries = LensLayout.entries(in: song)
        return LensLayout.words(in: entries, starts: entries.map(\.word.start), at: time, icons: false)
    }

    @Test func theSungWordIsBiggestAndBoxed() throws {
        let placed = words(at: 12.6)
        let biggest = try #require(placed.max { $0.scale < $1.scale })
        #expect(biggest.text == "on")
        #expect(biggest.boxed > 0.9)
        #expect(abs(biggest.y) < 0.05)
    }

    @Test func theColumnRunsAcrossLines() {
        let texts = words(at: 14.6).map(\.text)
        #expect(texts.contains("water") && texts.contains("lanterns"))
    }

    @Test func upcomingWordsAreFadedAndBelow() throws {
        let placed = words(at: 12.6)
        let current = try #require(placed.first { $0.text == "on" })
        let next = try #require(placed.first { $0.text == "quiet" })
        #expect(next.y > current.y)
        #expect(next.faded == 1 && next.boxed == 0)
    }
}

@Suite("Lyric colors")
struct LyricColorTests {
    @Test func grayCoversGetTheStandardColors() {
        #expect(LyricColors.fromArtwork(.fallback) == .standard)
    }

    @Test func vividCoversLeadWithTheirColor() {
        let palette = ArtworkPalette(
            primary: PaletteColor(red: 0.2, green: 0.5, blue: 1.0), secondary: .white, balance: 0.5
        )
        let colors = LyricColors.fromArtwork(palette)
        let highlight = ColorExtractor.HSB(colors.highlight)
        #expect(abs(highlight.hue - ColorExtractor.HSB(palette.primary).hue) < 0.02)
        #expect(highlight.saturation >= 0.62)
        #expect(ColorExtractor.HSB(colors.secondary).brightness < ColorExtractor.HSB(colors.lyric).brightness)
    }

    @Test func hexRoundTrips() throws {
        let color = PaletteColor(red: 0.89, green: 0.27, blue: 0.43)
        let back = try #require(PaletteColor(hex: color.hex))
        #expect(back.hex == color.hex)
        #expect(PaletteColor(hex: "nope") == nil)
    }
}

@Suite("Word icons")
struct WordIconTests {
    @Test(arguments: [
        ("Hearts,", "heart.fill"), ("dancing", "figure.dance"), ("dancin'", "figure.dance"),
        ("RAIN", "cloud.rain.fill"), ("stars...", "star.fill"), ("burned", "flame.fill"),
    ])
    func matches(word: String, symbol: String) {
        #expect(WordIcons.icon(for: word)?.symbol == symbol)
    }

    @Test(arguments: [
        ("you", "person.fill"), ("We", "person.2.fill"), ("me", "person.crop.circle.fill"),
        ("call", "phone.fill"), ("wait", "hourglass"), ("minutes", "clock.fill"), ("chances", "dice.fill"),
        ("blew", "wind"), ("telling", "bubble.left.fill"), ("start", "play.fill"), ("up", "arrow.up.circle.fill"),
    ])
    func everydayWords(word: String, symbol: String) {
        #expect(WordIcons.icon(for: word)?.symbol == symbol)
    }

    @Test(arguments: ["the", "a", "of", "and", "xyzzy", "", "uses", "i"])
    func ignores(word: String) {
        #expect(WordIcons.icon(for: word) == nil)
    }

    @Test func emojiForThingsSymbolsLack() throws {
        let angel = try #require(WordIcons.icon(for: "Angels"))
        #expect(angel.isEmoji && angel.symbol == "😇")
        #expect(WordIcons.icon(for: "heart")?.isEmoji == false)
    }

    @Test func vocabularyIsLarge() {
        #expect(WordIcons.vocabularySize >= 1000)
    }
}

@Suite("Frame pacing")
struct FramePaceTests {
    private let w = FramePaceConfig.fastWindow

    @Test func fastRightAfterAWordStarts() throws {
        let window = try #require(FramePace.window(starts: [1, 5, 9], at: 5.1))
        #expect(window.from == 5.1 && window.until == 5 + w)
    }

    @Test func calmBetweenWordsUntilTheNext() throws {
        let window = try #require(FramePace.window(starts: [1, 5, 9], at: 6))
        #expect(window.from == 9 && window.until == 9 + w)
    }

    @Test func quickWordsChainIntoOneWindow() throws {
        let window = try #require(FramePace.window(starts: [1, 1.2, 1.4, 5], at: 1.05))
        #expect(window.until == 1.4 + w)
    }

    @Test func nothingAfterTheLastWord() {
        #expect(FramePace.window(starts: [1, 2], at: 10) == nil)
    }

    @Test func intervals() {
        let pace = FramePace()
        let now = Date()
        pace.setFastWindow(from: now.addingTimeInterval(1), until: now.addingTimeInterval(2))
        #expect(pace.interval(after: now) == 1 / FramePaceConfig.calm)
        #expect(pace.interval(after: now.addingTimeInterval(1.5)) == 1 / FramePaceConfig.fast)
        #expect(pace.interval(after: now.addingTimeInterval(3)) == 1 / FramePaceConfig.calm)
    }
}
