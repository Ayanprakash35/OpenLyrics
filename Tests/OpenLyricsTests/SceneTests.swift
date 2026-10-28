import Foundation
import Testing
@testable import OpenLyrics

// Lyric text here is invented for the tests.

private func line(_ text: String, start: TimeInterval, step: TimeInterval = 0.5) -> LyricLine {
    let words = WordTiming.tokenize(text).enumerated().map { index, word in
        LyricWord(text: word.text, start: start + Double(index) * step, end: start + Double(index + 1) * step, spaceAfter: word.spaceAfter)
    }
    return LyricLine(start: start, end: start + Double(words.count) * step, words: words, hasWordTiming: true)
}

private func lyrics(_ lines: [LyricLine]) -> Lyrics {
    Lyrics(kind: .wordSynced, lines: lines, plainText: nil, source: "Test")
}

private func script(_ lines: [LyricLine], title: String = "Untitled", artist: String = "Nobody") -> SceneScript {
    SceneDirector.script(for: lyrics(lines), track: .init(title: title, artist: artist))
}

private func vehicles(in script: SceneScript) -> [String] {
    script.events.compactMap { if case .vehicle(let vehicle) = $0.kind { vehicle.glyph } else { nil } }
}

@Suite("Scenes")
struct SceneTests {
    private let plain = [
        line("walking down an empty street", start: 2),
        line("counting all the windows lit", start: 6),
        line("humming something old and slow", start: 10),
    ]

    @Test func plainLyricsHaveNoScenes() {
        #expect(script(plain).events.isEmpty)
    }

    @Test func irisRainsTheWholeSong() {
        for title in ["Iris", "Iris (Live)", "Iris - Remastered 2023", "Iris (Acoustic Version)"] {
            let result = script(plain, title: title, artist: "The Goo Goo Dolls")
            let rain = try? #require(result.events.first { $0.kind == .rain })
            #expect(rain != nil, "\(title)")
            #expect((rain?.start ?? 99) <= 2)
            #expect((rain?.end ?? 0) >= plain.last!.end)
        }
        // Another artist's song called Iris doesn't.
        #expect(script(plain, title: "Iris", artist: "Someone Else").events.isEmpty)
    }

    @Test func vivaLaVidaPopsAFrenchFlag() {
        let lines = plain + [line("viva the evening sky", start: 30)]
        for title in ["Viva la Vida", "Viva La Vida (Live in Paris)", "Viva la Vida - Cover"] {
            let flags = script(lines, title: title, artist: "Anyone").events.filter { $0.kind == .flag("🇫🇷") }
            #expect(flags.count == 2, "\(title)")
            // Once as the singing starts, once on "viva".
            #expect(flags.contains { $0.start == 2 })
            #expect(flags.contains { $0.start == 30 })
        }
    }

    @Test func wordsSetOffEffects() {
        let result = script([line("dancing in the rain tonight", start: 1)])
        let rain = result.events.first { $0.kind == .rain }
        #expect(rain?.start == 2.5)
        #expect((rain?.end ?? 0) >= 2.5 + SceneConfig.minimumEffect)
        #expect(script([line("my heart is beating", start: 1)]).events.contains { $0.kind == .hearts })
        #expect(script([line("baarish ki boondein", start: 1)]).events.contains { $0.kind == .rain })
    }

    @Test func repeatedWordsWaitForTheCooldown() {
        let lines = [
            line("rain rain go away", start: 1),
            line("rain again soon", start: 5),
            line("rain once more", start: 1 + SceneConfig.cooldown + 1),
        ]
        #expect(script(lines).events.filter { $0.kind == .rain }.count == 2)
    }

    @Test func carsAndModelsDriveBy() {
        #expect(vehicles(in: script([line("pull up in my cadillac", start: 1)])) == ["🚗"])
        #expect(vehicles(in: script([line("back seat of your rover", start: 1)])) == ["🚙"])
        #expect(vehicles(in: script([line("riding in a range rover", start: 1)])) == ["🚙"])
        #expect(vehicles(in: script([line("we took the train", start: 1)])) == ["🚆"])
        #expect(vehicles(in: script([line("a plane across the night", start: 1)])) == ["✈️"])
        #expect(vehicles(in: script([line("my car my cars", start: 1)])).count == 1)
    }

    @Test func rangeRoverIsOneVehicle() {
        let vehicle = Vehicles.vehicle(for: "range", next: "rover", previous: nil)
        #expect(vehicle?.glyph == "🚙")
        #expect(Vehicles.vehicle(for: "rover", next: nil, previous: "range") == nil)
        #expect(Vehicles.vehicle(for: "range", next: "of", previous: nil) == nil)
    }

    @Test func bridgeStartsAConstellation() throws {
        let lines = [
            line("meet me at the bridge tonight", start: 1),
            line("every word becomes a star", start: 5),
            line("lines are drawn between", start: 9),
            line("and then it all goes back", start: 13),
        ]
        let result = script(lines)
        let constellation = try #require(result.events.first { $0.kind == .constellation })
        #expect(constellation.start == 3)
        // It spans the line it starts in and the next two.
        #expect(constellation.end == lines[2].end)
        #expect(result.constellation(at: 6)?.start == 3)
        #expect(result.constellation(at: 14) == nil)
    }

    @Test func effectsStopWhenTheirTimeIsUp() {
        let event = SceneEvent(kind: .rain, start: 10, end: 20, seed: 1)
        #expect(event.envelope(at: 9) == 0)
        #expect(event.envelope(at: 10) == 0)
        #expect(event.envelope(at: 15) == 1)
        #expect(event.envelope(at: 21) == 0)
        #expect(SceneScript(events: [event]).active(at: 15).count == 1)
        #expect(SceneScript(events: [event]).active(at: 25).isEmpty)
    }
}

@Suite("Constellation")
struct ConstellationTests {
    private let source = lyrics([
        line("over the bridge we go walking", start: 1),
        line("one more step and then another", start: 5),
        line("everything we said is light", start: 9),
    ])

    private var event: SceneEvent { SceneEvent(kind: .constellation, start: 2, end: 13, seed: 42) }

    @Test func everyWordIsAStarJoinedToAnEarlierOne() {
        let nodes = ConstellationLayout.nodes(for: event, in: source)
        #expect(nodes.first?.text == "bridge")
        #expect(nodes.count == source.lines.flatMap(\.words).filter { $0.start >= 2 }.count)
        #expect(nodes.first?.parent == nil)
        for (index, node) in nodes.enumerated().dropFirst() {
            #expect((node.parent ?? index) < index)
            #expect(abs(node.x) <= ConstellationConfig.halfWidth)
            #expect(abs(node.y) <= ConstellationConfig.halfHeight)
        }
    }

    @Test func layoutIsTheSameEveryTime() {
        #expect(ConstellationLayout.nodes(for: event, in: source) == ConstellationLayout.nodes(for: event, in: source))
    }

    @Test func starsAppearAsTheyAreSung() {
        let nodes = ConstellationLayout.nodes(for: event, in: source)
        #expect(ConstellationLayout.frame(nodes: nodes, at: 1).stars.isEmpty)
        let early = ConstellationLayout.frame(nodes: nodes, at: nodes[2].start + 0.01)
        #expect(early.stars.count == 3)
        // Only the sung word's star has the ring, and its label is the biggest.
        #expect(early.stars.filter { $0.ring > 0 }.count == 1)
        let late = ConstellationLayout.frame(nodes: nodes, at: 12.9)
        #expect(late.stars.count == nodes.count)
        let current = late.labels.max { $0.scale < $1.scale }
        #expect(current?.text == nodes.last?.text)
        #expect(late.labels.count <= ConstellationConfig.labelsShown + 1)
    }

    @Test func handoffNeverShowsBothAtOnce() {
        for takeover in stride(from: 0.0, through: 1, by: 0.05) {
            let (words, stars) = ConstellationLayout.handoff(takeover)
            #expect(words == 0 || stars == 0)
        }
        #expect(ConstellationLayout.handoff(0) == (1, 0))
        #expect(ConstellationLayout.handoff(1) == (0, 1))
    }
}

@Suite("Easter eggs and languages")
struct EasterEggAndLanguageTests {
    @Test func matchesTitlesLoosely() {
        #expect(EasterEggs.match(title: "Purple Rain", artist: "Prince")?.ambient == .rain)
        #expect(EasterEggs.match(title: "IRIS", artist: "Goo Goo Dolls")?.ambient == .rain)
        #expect(EasterEggs.match(title: "Viva la Vida", artist: "")?.flag == "🇫🇷")
        #expect(EasterEggs.match(title: "Viva", artist: "Coldplay") == nil)
    }

    @Test func devanagariWordsGetIcons() {
        #expect(WordIcons.candidates(for: "दिल,").contains("दिल"))
        #expect(WordIcons.icon(for: "दिल") != nil)
    }

    @Test func singleCharacterWordsInSpacelessScripts() {
        #expect(WordIcons.icon(for: "雨") != nil)
        #expect(WordIcons.icon(for: "a") == nil)
    }

    @Test func romanizedHindiWordsGetIcons() {
        #expect(WordIcons.icon(for: "dil") != nil)
        #expect(WordIcons.icon(for: "chaand") != nil || WordIcons.icon(for: "chand") != nil)
    }
}
