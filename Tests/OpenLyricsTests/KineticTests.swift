import CoreGraphics
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

    @Test func neighboringWordsGetDifferentColorSlots() throws {
        let words = StackLayout.words(in: song, at: 12.6, icons: false)
        let slots = words.map(\.colorSlot)
        #expect(Set(slots).count == slots.count)
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

    @Test func coversGiveGradientsFromTheirColors() {
        // Green and blue, like a green-and-blue cover.
        let green = PaletteColor(red: 0.42, green: 0.92, blue: 0.55)
        let blue = PaletteColor(red: 0.30, green: 0.62, blue: 1.0)
        let teal = PaletteColor(red: 0.20, green: 0.80, blue: 0.82)
        let colors = LyricColors.fromArtwork(accents: [green, blue, teal])
        func hue(_ color: PaletteColor) -> Double { ColorExtractor.HSB(color).hue }
        // Lyrics run from the leading color to the second; the box from the second to the leading.
        #expect(abs(hue(colors.lyric) - hue(green)) < 0.02)
        #expect(abs(hue(colors.lyricEnd) - hue(blue)) < 0.02)
        #expect(abs(hue(colors.highlight) - hue(blue)) < 0.02)
        #expect(abs(hue(colors.highlightEnd) - hue(green)) < 0.02)
        #expect(abs(hue(colors.secondary) - hue(teal)) < 0.02)
        #expect(ColorExtractor.HSB(colors.highlight).saturation >= 0.62)
        #expect(ColorExtractor.HSB(colors.secondary).brightness < ColorExtractor.HSB(colors.lyric).brightness)
    }

    @Test func aSingleColorCoverStillGetsAGradient() {
        let colors = LyricColors.fromArtwork(accents: [PaletteColor(red: 0.2, green: 0.5, blue: 1.0)])
        #expect(colors.lyric != colors.lyricEnd)
        #expect(colors.highlight != colors.highlightEnd)
    }

    @Test func grayAccentsAreSkipped() {
        let gray = PaletteColor(red: 0.6, green: 0.6, blue: 0.6)
        let red = PaletteColor(red: 1, green: 0.3, blue: 0.3)
        let colors = LyricColors.fromArtwork(accents: [gray, red])
        #expect(abs(ColorExtractor.HSB(colors.lyric).hue - ColorExtractor.HSB(red).hue) < 0.02)
    }

    @Test func perWordGivesNeighborsDifferentSolidColors() {
        let green = PaletteColor(red: 0.42, green: 0.92, blue: 0.55)
        let blue = PaletteColor(red: 0.30, green: 0.62, blue: 1.0)
        var colors = LyricColors.fromArtwork(accents: [green, blue])
        colors.perWord = true
        let first = colors.resolved(slot: 0), second = colors.resolved(slot: 1)
        #expect(first.highlight != second.highlight)
        #expect(first.highlight == first.highlightEnd)
        #expect(colors.resolved(slot: 2) == first)
        #expect(colors.resolved(slot: -1) == second)
    }

    @Test func gradientModeSharesTheGradients() {
        var colors = LyricColors.fromArtwork(accents: [PaletteColor(red: 0.42, green: 0.92, blue: 0.55)])
        colors.perWord = false
        #expect(colors.resolved(slot: 0) == colors.resolved(slot: 5))
        #expect(colors.resolved(slot: 0).highlight != colors.resolved(slot: 0).highlightEnd)
    }

    @Test func singleColorCoversStillVaryPerWord() {
        var colors = LyricColors.fromArtwork(accents: [PaletteColor(red: 0.2, green: 0.5, blue: 1.0)])
        colors.perWord = true
        #expect(Set([0, 1, 2].map { colors.resolved(slot: $0).highlight.hex }).count == 3)
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

@Suite("Beat bounce")
struct BeatTests {
    private let words = [
        LyricWord(text: "a", start: 1, end: 1.3, spaceAfter: true),
        LyricWord(text: "b", start: 2, end: 3, spaceAfter: false),
        LyricWord(text: "c", start: 4, end: 4.2, spaceAfter: false),
    ]
    private let lineStarts = [true, false, true]

    @Test func silentBeforeTheFirstWordAndLongAfter() {
        #expect(Beat.fromLyrics(words: words, lineStarts: lineStarts, at: 0.5) == .none)
        #expect(Beat.fromLyrics(words: words, lineStarts: lineStarts, at: 6) == .none)
    }

    @Test func hitsAtEachWordAndFades() {
        let atHit = Beat.fromLyrics(words: words, lineStarts: lineStarts, at: 2.0)
        let later = Beat.fromLyrics(words: words, lineStarts: lineStarts, at: 2.4)
        #expect(atHit.pulse > later.pulse)
        #expect(later.hop == 0)
        let midHop = Beat.fromLyrics(words: words, lineStarts: lineStarts, at: 2.0 + BeatConfig.hopDuration / 2)
        #expect(midHop.hop > 0.5)
    }

    @Test func lineStartsHitHarderThanPlainWords() {
        let lineStart = Beat.fromLyrics(words: words, lineStarts: lineStarts, at: 4.0)
        let plain = Beat.fromLyrics(words: [words[2]], lineStarts: [false], at: 4.0)
        #expect(lineStart.pulse > plain.pulse)
    }

    @Test func heldNotesHitAlittleHarder() {
        let held = Beat.fromLyrics(words: [words[1]], lineStarts: [false], at: 2.0)
        let short = Beat.fromLyrics(words: [words[2]], lineStarts: [false], at: 4.0)
        #expect(held.pulse > short.pulse)
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

@Suite("Artwork accents")
struct ArtworkAccentTests {
    /// A 64×64 cover, left half `left`, right half `right`.
    private func cover(_ left: CGColor, _ right: CGColor) -> CGImage {
        let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(left)
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 64))
        context.setFillColor(right)
        context.fill(CGRect(x: 32, y: 0, width: 32, height: 64))
        return context.makeImage()!
    }

    @Test func aTwoColorCoverReportsBoth() {
        let green = CGColor(srgbRed: 0.1, green: 0.7, blue: 0.3, alpha: 1)
        let blue = CGColor(srgbRed: 0.1, green: 0.3, blue: 0.8, alpha: 1)
        let accents = ColorExtractor.extract(from: cover(green, blue)).accents
        let hues = accents.map { ColorExtractor.HSB($0).hue }
        #expect(accents.count == 2)
        #expect(hues.contains { (0.3...0.45).contains($0) })  // green
        #expect(hues.contains { (0.55...0.7).contains($0) })  // blue
    }

    @Test func grayCoversReportWhiteAndSilver() {
        let accents = ColorExtractor.extract(from: cover(CGColor(gray: 0.2, alpha: 1), CGColor(gray: 0.8, alpha: 1))).accents
        #expect(accents.count == 2)
        #expect(accents.allSatisfy { ColorExtractor.HSB($0).saturation < 0.18 })
    }
}
