import Foundation
import Testing
@testable import OpenLyrics

// Every lyric line in these tests is invented for them.

@Suite("LRC parsing")
struct LRCParserTests {
    @Test(arguments: [
        ("01:02.50", 62.5), ("01:02.5", 62.5), ("01:02.500", 62.5), ("01:02", 62.0),
        ("1:02.25", 62.25), ("01:02:50", 62.5), ("1:01:02.00", 3662.0), ("00:00.00", 0.0),
    ])
    func timestamps(text: String, seconds: Double) {
        #expect(LRCParser.timestamp(Substring(text)) == seconds)
    }

    @Test(arguments: ["ar:Some Artist", "ti:Title", "01:60.00", "aa:bb", "01:02.5000", "", "offset:+100"])
    func notTimestamps(text: String) {
        #expect(LRCParser.timestamp(Substring(text)) == nil)
    }

    @Test func linesAreSortedTimedAndEnded() throws {
        let text = """
        [ar:Nobody]
        [ti:Test Song]
        [00:05.00]paper boats on a quiet street
        [00:01.00]lanterns hum above the bay
        [00:09.50]counting stars we never meet
        """
        let lyrics = try #require(LRCParser.parse(text, source: "Test", duration: 20))
        #expect(lyrics.kind == .lineSynced)
        #expect(lyrics.lines.map(\.text) == [
            "lanterns hum above the bay", "paper boats on a quiet street", "counting stars we never meet",
        ])
        #expect(lyrics.lines.map(\.start) == [1, 5, 9.5])
        #expect(lyrics.lines[0].end == 5)
        #expect(lyrics.lines[1].end == 9.5)
        #expect(lyrics.lines[2].end == 20)
    }

    @Test func repeatedTimestampsRepeatTheLine() throws {
        let lyrics = try #require(LRCParser.parse("[00:01.00][00:10.00]hold on, hold on\n[00:05.00]in between", source: "Test", duration: nil))
        #expect(lyrics.lines.map(\.text) == ["hold on, hold on", "in between", "hold on, hold on"])
    }

    @Test func offsetShiftsEveryLine() throws {
        let lyrics = try #require(LRCParser.parse("[offset:+500]\n[00:02.00]first light\n[00:04.00]second wind", source: "Test", duration: nil))
        #expect(lyrics.lines.map(\.start) == [1.5, 3.5])
    }

    @Test func emptyAndMusicNoteLinesBecomeGaps() throws {
        let text = "[00:01.00]one small step\n[00:03.00]\n[00:20.00]♪ ♪\n[00:30.00]back again"
        let lyrics = try #require(LRCParser.parse(text, source: "Test", duration: 40))
        // The empty line and the note line merge into one gap from 3 to 30.
        #expect(lyrics.lines.map(\.isGap) == [false, true, false])
        #expect(lyrics.lines[1].start == 3)
        #expect(lyrics.lines[1].end == 30)
    }

    @Test func longIntroGetsAGapFirst() throws {
        let lyrics = try #require(LRCParser.parse("[00:12.00]finally, the words", source: "Test", duration: nil))
        #expect(lyrics.lines.first?.isGap == true)
        #expect(lyrics.lines.first?.end == 12)
    }

    @Test func netEaseCreditsAndJSONLinesAreSkipped() throws {
        let text = """
        {"t":0,"c":[{"tx":"作曲: "},{"tx":"Someone"}]}
        [00:00.00] 作词 : Someone Else
        [00:00.50] Composer: A Person
        [00:02.00]the first real line
        """
        let lyrics = try #require(LRCParser.parse(text, source: "Test", duration: nil))
        #expect(lyrics.lines.filter { !$0.isGap }.map(\.text) == ["the first real line"])
    }

    @Test func enhancedWordTags() throws {
        let text = "[00:10.00]<00:10.00>slow <00:10.50>and <00:11.00>steady<00:12.00>\n[00:14.00]next"
        let lyrics = try #require(LRCParser.parse(text, source: "Test", duration: nil))
        #expect(lyrics.kind == .wordSynced)
        // The line starts 10 s in, so an intro gap comes first.
        #expect(lyrics.lines.first?.isGap == true)
        let words = try #require(lyrics.lines.first { !$0.isGap }).words
        #expect(words.map(\.text) == ["slow", "and", "steady"])
        #expect(words.map(\.start) == [10, 10.5, 11])
        #expect(words.map(\.end) == [10.5, 11, 12])
        #expect(words.map(\.spaceAfter) == [true, true, false])
    }

    @Test func untimedTextIsUnsynced() throws {
        let lyrics = try #require(LRCParser.parse("just words\nno times here", source: "Test", duration: nil))
        #expect(lyrics.kind == .unsynced)
        #expect(lyrics.plainText == "just words\nno times here")
        #expect(lyrics.lines.isEmpty)
    }

    @Test func nothingUsableIsNil() {
        #expect(LRCParser.parse("", source: "Test", duration: nil) == nil)
        #expect(LRCParser.parse("[ar:Only Tags]\n[ti:Here]", source: "Test", duration: nil) == nil)
    }

    @Test func lineIndexFindsTheCurrentLine() throws {
        let lyrics = try #require(LRCParser.parse("[00:01.00]a\n[00:02.00]b\n[00:03.00]c", source: "Test", duration: nil))
        #expect(lyrics.lineIndex(at: 0.5) == nil)
        #expect(lyrics.lineIndex(at: 1) == 0)
        #expect(lyrics.lineIndex(at: 2.99) == 1)
        #expect(lyrics.lineIndex(at: 100) == 2)
    }
}

@Suite("YRC parsing")
struct YRCParserTests {
    @Test func wordsCarryTheirOwnTiming() throws {
        let text = """
        {"t":0,"c":[{"tx":"作词: "},{"tx":"Someone"}]}
        [4000,3000](4000,500,0)Morning (4500,700,0)comes (5200,1800,0)slowly
        [8000,2000](8000,1000,0)wake (9000,1000,0)up
        """
        let lyrics = try #require(YRCParser.parse(text, source: "NetEase", duration: 30))
        #expect(lyrics.kind == .wordSynced)
        let sung = lyrics.lines.filter { !$0.isGap }
        #expect(sung.map(\.text) == ["Morning comes slowly", "wake up"])
        #expect(sung[0].words.map(\.start) == [4, 4.5, 5.2])
        #expect(sung[0].words.map(\.end) == [4.5, 5.2, 7])
        #expect(sung[0].words.map(\.spaceAfter) == [true, true, false])
        #expect(sung[0].end == 8)
    }

    @Test func syllablesOfOneWordStayJoined() throws {
        let words = YRCParser.words(in: "(1000,200,0)beau(1200,200,0)ti(1400,300,0)ful (1700,400,0)day")
        #expect(words.map(\.text) == ["beau", "ti", "ful", "day"])
        #expect(words.map(\.spaceAfter) == [false, false, true, false])
    }

    @Test func parenthesesInsideWordsSurvive() {
        let words = YRCParser.words(in: "(1000,300,0)(oh) (1300,300,0)yes")
        #expect(words.map(\.text) == ["(oh)", "yes"])
    }

    @Test func aLongPauseAfterTheLastWordBecomesAGap() throws {
        let text = "[1000,2000](1000,500,0)short (1500,500,0)line\n[20000,1000](20000,1000,0)later"
        let lyrics = try #require(YRCParser.parse(text, source: "NetEase", duration: nil))
        #expect(lyrics.lines.map(\.isGap) == [false, true, false])
        #expect(lyrics.lines[1].start == 2)
        #expect(lyrics.lines[1].end == 20)
    }
}

@Suite("Word timing")
struct WordTimingTests {
    @Test func tokenizesOnSpaces() {
        let words = WordTiming.tokenize("  we  ride   tonight ")
        #expect(words.map(\.text) == ["we", "ride", "tonight"])
        #expect(words.map(\.spaceAfter) == [true, true, false])
    }

    @Test func splitsSpacelessScriptsPerCharacter() {
        let words = WordTiming.tokenize("我们 走吧 ok")
        #expect(words.map(\.text) == ["我", "们", "走", "吧", "ok"])
        #expect(words.map(\.spaceAfter) == [false, true, false, true, false])
    }

    @Test func estimatesFillTheLineInOrder() {
        let words = WordTiming.estimate(WordTiming.tokenize("a longer word here"), start: 10, end: 20)
        #expect(words.first?.start == 10)
        for (a, b) in zip(words, words.dropFirst()) {
            #expect(a.end == b.start)
            #expect(a.start < a.end)
        }
        // Long words take longer than short ones.
        #expect(words[1].end - words[1].start > words[0].end - words[0].start)
        // Sung at a natural pace, not stretched over the whole ten seconds.
        let last = try! #require(words.last)
        #expect(last.end < 13)
    }

    @Test func neverRunsPastTheNextLine() {
        let words = WordTiming.estimate(WordTiming.tokenize("a very long line squeezed into a tiny slot of time"), start: 0, end: 1)
        #expect((words.last?.end ?? 0) <= 1)
    }

    @Test func wordProgress() {
        let word = LyricWord(text: "x", start: 1, end: 3, spaceAfter: false)
        #expect(word.progress(at: 0) == 0)
        #expect(word.progress(at: 2) == 0.5)
        #expect(word.progress(at: 5) == 1)
    }
}
