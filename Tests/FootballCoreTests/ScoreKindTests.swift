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
