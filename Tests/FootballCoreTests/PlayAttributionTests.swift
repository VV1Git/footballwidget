import Foundation
import Testing
@testable import FootballCore

private func rosterPlayer(
    _ id: Int, _ first: String, _ last: String,
    position: FantasyPosition = .wideReceiver,
    slot: LineupSlot = .starting("WR"),
    team: Int? = 26,
    points: Double = 0
) -> RosterPlayer {
    RosterPlayer(id: id, fullName: "\(first) \(last)", firstName: first, lastName: last,
                 position: position, slot: slot, proTeamID: team, points: points,
                 injuryStatus: nil)
}

// Real players from the recorded NE @ SEA game, with their real ESPN athlete ids.
private let darnold = rosterPlayer(3912547, "Sam", "Darnold", position: .quarterback,
                                   slot: .starting("QB"), team: 26)
private let smithNjigba = rosterPlayer(4430878, "Jaxon", "Smith-Njigba", team: 26)
private let maye = rosterPlayer(4431452, "Drake", "Maye", position: .quarterback,
                                slot: .starting("QB"), team: 17)

private let candidates: [(player: RosterPlayer, isMine: Bool)] = [
    (darnold, true), (smithNjigba, true), (maye, false),
]

// MARK: - Name parsing

@Test func parsesNamesOutOfRealPlayText() {
    let text = "(Shotgun) S.Darnold pass short middle to J.Smith-Njigba to 50 for 13 yards (R.Spillane)."
    let names = PlayAttribution.names(in: text)
    let rendered = names.map { "\($0.initial).\($0.surname)" }
    #expect(rendered == ["S.Darnold", "J.Smith-Njigba", "R.Spillane"])
}

@Test func handlesHyphensAndNoNames() {
    #expect(PlayAttribution.names(in: "END GAME").isEmpty)
    #expect(PlayAttribution.names(in: "Two-minute warning").isEmpty)
    let penalty = PlayAttribution.names(in: "PENALTY on SEA-E.Saubert, False Start, 5 yards.")
    #expect(penalty.map(\.surname) == ["Saubert"])
}

// MARK: - Matching

@Test func creditsThePlayersAPlayNames() {
    let text = "S.Darnold pass short middle to J.Smith-Njigba to 50 for 13 yards (R.Spillane)."
    let found = PlayAttribution.players(namedIn: text, candidates: candidates)
    #expect(found.map(\.player.id) == [darnold.id, smithNjigba.id])
    let allMine = found.allSatisfy { $0.isMine }
    #expect(allMine)
}

/// A defender named in the tackle parenthetical is not on this play's offense, but he
/// *is* named — if he were rostered he genuinely earns a tackle. What matters is that
/// nobody unrostered gets credited.
@Test func ignoresPlayersWhoAreNotRostered() {
    let text = "J.Price right tackle to SEA 37 for 13 yards (K.Byard; E.Ponder)."
    #expect(PlayAttribution.players(namedIn: text, candidates: candidates).isEmpty)
}

@Test func requiresTheFirstInitialToAgree() {
    // "T.Darnold" is not Sam Darnold.
    let found = PlayAttribution.players(namedIn: "T.Darnold scrambles for 4 yards.",
                                        candidates: candidates)
    #expect(found.isEmpty)
}

/// Two rostered players sharing an initial and surname cannot be told apart from the
/// play text, so neither is credited.
@Test func skipsAmbiguousSurnames() {
    let one = rosterPlayer(1, "Josh", "Allen", team: 2)
    let two = rosterPlayer(2, "Jordan", "Allen", team: 2)
    let found = PlayAttribution.players(namedIn: "J.Allen pass complete for 12 yards.",
                                        candidates: [(one, true), (two, false)])
    #expect(found.isEmpty)
}

@Test func creditsEachPlayerOnlyOnce() {
    // Sacks name the quarterback twice.
    let text = "(Shotgun) S.Darnold sacked at SEA 49 for -5 yards (D.Jones). SEA-S.Darnold was injured."
    let found = PlayAttribution.players(namedIn: text, candidates: candidates)
    #expect(found.count == 1)
    #expect(found.first?.player.id == darnold.id)
}

// MARK: - Points

@Test func attachesKnownPointDeltas() throws {
    let text = "S.Darnold pass short middle to J.Smith-Njigba for 13 yards."
    let credits = PlayAttribution.credits(
        forPlayText: text,
        candidates: candidates,
        deltas: [smithNjigba.id: 2.3]
    )
    #expect(credits.count == 2)
    let receiver = try #require(credits.first { $0.playerID == smithNjigba.id })
    #expect(receiver.points == 2.3)
    // The quarterback was named but has no delta tied to this play yet.
    let quarterback = try #require(credits.first { $0.playerID == darnold.id })
    #expect(quarterback.points == nil)
}

@Test func deltasIgnoreFirstSightingAndNoise() {
    let deltas = PlayAttribution.deltas(
        previous: [1: 10.0, 2: 5.0],
        current: [1: 16.4, 2: 5.0, 3: 8.0]   // 3 is newly seen
    )
    #expect(deltas[1] == 6.4)
    #expect(deltas[2] == nil)     // unchanged
    #expect(deltas[3] == nil)     // first sighting is silent
}

/// ESPN issues stat corrections, which move totals down. The delta is reported so
/// running totals stay right; callers decide not to alert on it.
@Test func deltasReportDownwardCorrections() throws {
    let deltas = PlayAttribution.deltas(previous: [1: 12.0], current: [1: 6.0])
    let value = try #require(deltas[1])
    #expect(value == -6.0)
}

// MARK: - Plays that cannot score

private func play(_ id: String, _ sequence: Int, _ text: String) -> Play {
    Play(id: id, sequence: sequence, typeID: nil, typeText: "", text: text,
         downDistanceText: nil, yards: 0, period: 2, clock: "7:15",
         isScoring: false, isTurnover: false, isPenalty: false,
         start: PlayNode(), end: PlayNode(), kind: .scrimmage)
}

private func detail(plays: [Play]) -> GameDetail {
    let drive = Drive(id: "d1", teamID: "26", teamAbbreviation: "SEA", result: "",
                      isScore: false, yards: 0, playCount: plays.count, timeElapsed: "",
                      summary: "", startText: nil, plays: plays, isCurrent: true)
    return GameDetail(gameID: "1", drives: [drive], scoringPlayIDs: [])
}

@Test func incompletionsAndNoPlaysCannotScore() {
    let incomplete = "(Shotgun) D.Lock pass incomplete short right to J.Smith-Njigba."
    #expect(!PlayAttribution.canScore(playText: incomplete))
    #expect(!PlayAttribution.canScore(
        playText: "S.Darnold pass short left to J.Smith-Njigba for 12 yards. PENALTY on SEA-A.Lawrence, Holding, 10 yards, NULLIFIED."))
    #expect(PlayAttribution.canScore(
        playText: "S.Darnold pass short middle to J.Smith-Njigba for 13 yards (R.Spillane)."))
    #expect(PlayAttribution.canScore(playText: "K.Walker left end to SEA 30 for 5 yards."))
}

/// ESPN's fantasy totals arrive a poll after the play feed, so a catch's points land
/// while the newest play naming the receiver is the incompletion thrown his way next.
/// The points belong to the catch.
@Test func pointsLandOnTheCatchNotTheIncompletionAfterIt() throws {
    let catchPlay = play("catch", 1, "(Shotgun) D.Lock pass deep right to J.Smith-Njigba for 28 yards (C.Ward).")
    let incomplete = play("miss", 2, "(Shotgun) D.Lock pass incomplete short right to J.Smith-Njigba.")
    let found = PlayAttribution.mostRecentPlay(
        naming: smithNjigba, in: detail(plays: [catchPlay, incomplete])
    )
    #expect(found?.id == "catch")
}

@Test func noScoringPlayMeansNoAttribution() {
    let incomplete = play("miss", 1, "(Shotgun) D.Lock pass incomplete short right to J.Smith-Njigba.")
    #expect(PlayAttribution.mostRecentPlay(naming: smithNjigba, in: detail(plays: [incomplete])) == nil)
}

// MARK: - Against the whole recorded game

@Test func runsOverEveryPlayOfARealGameWithoutFalsePositives() throws {
    let located = Bundle.module.url(forResource: "summary", withExtension: "json",
                                    subdirectory: "Fixtures")
    let url = try #require(located)
    let dto = try JSONDecoder().decode(ESPNSummaryDTO.self, from: Data(contentsOf: url))
    let detail = ESPNMapper.detail(from: dto, gameID: "401872656")

    var credited = 0
    var plays = 0
    for drive in detail.drives {
        for play in drive.plays {
            plays += 1
            let credits = PlayAttribution.credits(
                forPlayText: play.text, candidates: candidates, deltas: [:]
            )
            // Only the three rostered players may ever be credited.
            let known = [darnold.id, smithNjigba.id, maye.id]
            let onlyKnown = credits.allSatisfy { known.contains($0.playerID) }
            #expect(onlyKnown, "unexpected credit in: \(play.text)")
            credited += credits.count
        }
    }

    #expect(plays == 179)
    // Both quarterbacks played the whole game, so a real roster must pick up plenty.
    #expect(credited > 50, "expected many credits across a full game, got \(credited)")
}
