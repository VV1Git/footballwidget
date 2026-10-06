import Foundation
import Testing
@testable import FootballCore

// The ladder once labelled every scoring play "TD", so a field goal showed as a
// touchdown, and a kicker's field goal skipped the fantasy alert threshold as one.
// These pin the score kind to ESPN's `scoringType` rather than to the play type.

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json",
                                             subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private func play(_ json: String) throws -> ESPNPlayDTO {
    try JSONDecoder().decode(ESPNPlayDTO.self, from: Data(json.utf8))
}

@Test func recordedFieldGoalIsNotATouchdown() throws {
    let dto = try JSONDecoder().decode(ESPNSummaryDTO.self, from: fixture("summary"))
    let plays = ESPNMapper.detail(from: dto, gameID: "401872656").drives.flatMap(\.plays)

    let fieldGoal = try #require(plays.first { $0.text.contains("field goal is GOOD") })
    #expect(fieldGoal.isScoring)
    #expect(fieldGoal.scoreKind == .fieldGoal)
    #expect(fieldGoal.scoreKind?.label == "FG")

    let touchdown = try #require(plays.first { $0.isScoring && $0.text.contains("TOUCHDOWN") })
    #expect(touchdown.scoreKind == .touchdown)
    #expect(touchdown.scoreKind?.label == "TD")

    // Exactly the scoring plays carry a kind.
    #expect(plays.allSatisfy { ($0.scoreKind != nil) == $0.isScoring })
}

/// A blocked field goal returned for a touchdown is typed "Blocked Field Goal".
@Test func scoringTypeWinsOverPlayType() throws {
    let blocked = try play("""
    {"scoringPlay": true, "type": {"id": "18", "text": "Blocked Field Goal"},
     "scoringType": {"name": "touchdown", "abbreviation": "TD"},
     "text": "J.Karty 44 yard field goal is BLOCKED (J.Davis), RECOVERED by DET-B.Branch. B.Branch for 62 yards, TOUCHDOWN."}
    """)
    #expect(ESPNMapper.scoreKind(from: blocked) == .touchdown)

    let penaltySafety = try play("""
    {"scoringPlay": true, "type": {"id": "8", "text": "Penalty"},
     "scoringType": {"name": "safety", "abbreviation": "SF"},
     "text": "B.Nix pass incomplete deep right. PENALTY on DEN-A.Palczewski, Offensive Holding, enforced in End Zone, SAFETY."}
    """)
    #expect(ESPNMapper.scoreKind(from: penaltySafety) == .safety)
}

/// ESPN occasionally leaves `scoringType` off; the text is the fallback.
@Test func missingScoringTypeFallsBackToText() throws {
    let returned = try play("""
    {"scoringPlay": true, "type": {"id": "39", "text": "Fumble Return Touchdown"},
     "text": "George Holani Recovered Kickoff in End Zone for a Touchdown (Jason Myers Kick)"}
    """)
    #expect(ESPNMapper.scoreKind(from: returned) == .touchdown)

    let kick = try play("""
    {"scoringPlay": true, "type": {"id": "59"},
     "text": "E.Pineiro 56 yard field goal is GOOD, Center-J.Weeks, Holder-C.Waitman."}
    """)
    #expect(ESPNMapper.scoreKind(from: kick) == .fieldGoal)

    let unknown = try play(#"{"scoringPlay": true, "text": "Scoring play"}"#)
    #expect(ESPNMapper.scoreKind(from: unknown) == .other)

    let notScoring = try play(#"{"scoringPlay": false, "text": "field goal is GOOD"}"#)
    #expect(ESPNMapper.scoreKind(from: notScoring) == nil)
}

// MARK: - Status from the play feed

private func halftimeGame(lastPlay: String = "half", typeID: String = "65") -> Game {
    Game(id: "401872979", shortName: "ATL @ NO", phase: .halftime, statusDetail: "Halftime",
         period: 2, displayClock: "0:00",
         home: TeamSide(id: "18", abbreviation: "NO", displayName: "NO", shortName: "NO", score: 10),
         away: TeamSide(id: "1", abbreviation: "ATL", displayName: "ATL", shortName: "ATL", score: 7),
         situation: Situation(lastPlayID: lastPlay, lastPlayTypeID: typeID))
}

@Test func statusProgressOrdersHalftimeBetweenTheQuarters() {
    let endOfSecond = GameStatus(phase: .live, period: 2, displayClock: "0:00", statusDetail: "")
    let half = GameStatus(phase: .halftime, period: 2, displayClock: "0:00", statusDetail: "")
    let thirdKickoff = GameStatus(phase: .live, period: 3, displayClock: "15:00", statusDetail: "")
    let thirdLater = GameStatus(phase: .live, period: 3, displayClock: "7:38", statusDetail: "")
    #expect(endOfSecond.progress < half.progress)
    #expect(half.progress < thirdKickoff.progress)
    #expect(thirdKickoff.progress < thirdLater.progress)
}

/// Recorded live: the scoreboard sat on "Halftime" while the play feed's header said
/// 3rd quarter, 7:38 — and had the plays to prove it.
@Test func aFeedAheadOfTheScoreboardMovesTheGameOn() {
    let feed = GameStatus(phase: .live, period: 3, displayClock: "7:38", statusDetail: "7:38 - 3rd",
                          homeScore: 13, awayScore: 7)
    let game = halftimeGame().reconciled(with: feed)
    #expect(game.phase == .live)
    #expect(game.period == 3)
    #expect(game.displayClock == "7:38")
    #expect(game.home.score == 13)

    // A feed behind the scoreboard changes nothing.
    let stale = GameStatus(phase: .live, period: 2, displayClock: "1:10", statusDetail: "")
    #expect(halftimeGame().reconciled(with: stale) == halftimeGame())
}

@Test func aSnapSinceHalftimeMeansTheSecondHalfHasStarted() {
    #expect(halftimeGame().resumedAfterHalftime(halftimeLastPlay: "half").phase == .halftime)
    let kicked = halftimeGame(lastPlay: "kickoff", typeID: "53").resumedAfterHalftime(halftimeLastPlay: "half")
    #expect(kicked.phase == .live)
    #expect(kicked.period == 3)
    // A timeout is not a snap.
    let timeout = halftimeGame(lastPlay: "to", typeID: "21").resumedAfterHalftime(halftimeLastPlay: "half")
    #expect(timeout.phase == .halftime)
}

@Test func theRecordedFeedCarriesItsStatus() throws {
    let located = Bundle.module.url(forResource: "summary", withExtension: "json", subdirectory: "Fixtures")
    let url = try #require(located)
    let dto = try JSONDecoder().decode(ESPNSummaryDTO.self, from: Data(contentsOf: url))
    let status = try #require(ESPNMapper.detail(from: dto, gameID: "401872656").status)
    #expect(status.phase == .final)
    #expect(status.homeScore != nil && status.awayScore != nil)
}
