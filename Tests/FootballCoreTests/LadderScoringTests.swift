import Foundation
import Testing
@testable import FootballCore

// How the field ladder labels scores, turnovers and drive endings. Checked against every
// drive and play of the recorded NE @ SEA game, and against the play shapes that game
// does not have.

private func ladderDetail() throws -> GameDetail {
    let url = try #require(Bundle.module.url(forResource: "summary", withExtension: "json",
                                             subdirectory: "Fixtures"))
    let dto = try JSONDecoder().decode(ESPNSummaryDTO.self, from: Data(contentsOf: url))
    return ESPNMapper.detail(from: dto, gameID: "401872656")
}

private func ladderPlay(
    _ id: String, _ text: String, type: String? = nil, offense: String = "17",
    ending: String? = nil, down: Int? = nil, score: ScoreKind? = nil, turnover: Bool = false,
    from start: Int = 60, to end: Int = 40, kind: PlayKind = .scrimmage
) -> Play {
    Play(id: id, sequence: 0, typeID: type, typeText: "", text: text,
         downDistanceText: down.map { "\($0)th & 5 at NE 40" }, yards: 0, period: 2, clock: "5:00",
         isScoring: score != nil, scoreKind: score, isTurnover: turnover, isPenalty: false,
         start: PlayNode(teamID: offense, yardsToEndzone: start, down: down),
         end: PlayNode(teamID: ending ?? offense, yardsToEndzone: end), kind: kind)
}

private func ladderDrive(_ plays: [Play], result: String, isScore: Bool = false,
                         team: String = "17") -> Drive {
    Drive(id: "d", teamID: team, teamAbbreviation: "NE", result: result, isScore: isScore,
          yards: 0, playCount: plays.count, timeElapsed: "", summary: "", startText: nil,
          plays: plays, isCurrent: false)
}

// MARK: - The recorded game

/// Every way a drive in the recorded game ended, and whether the banner may say who has
/// the ball: after a punt or a pick it changed hands; after a score, or the half or the
/// game running out, it did not. It used to read "END OF GAME · NE ball".
@Test func recordedDriveEndingsSayWhoHasTheBall() throws {
    let drives = try ladderDetail().drives
    var seen: [String: Bool] = [:]
    for drive in drives {
        let outcome = try #require(drive.outcome)
        seen[outcome] = drive.possessionChanges
        #expect(!drive.opponentScored, "\(outcome)")
        #expect(drive.offenseScored == drive.isScore, "\(outcome)")
    }
    #expect(seen == [
        "Punt": true, "Interception": true,
        "Touchdown": false, "Field Goal": false,
        "End of Half": false, "End of Game": false,
    ])
}

/// Every row the recorded game draws: the punts and picks are labelled as what they
/// were, the five scores carry TD or FG, and nothing is called "On downs".
@Test func recordedLadderLabelsMatchWhatHappened() throws {
    let detail = try ladderDetail()
    var handovers: [String] = []
    var scores: [String] = []
    for drive in detail.drives {
        for row in FieldGeometry.rows(for: drive) {
            if row.flipsFrame { handovers.append(row.situationLabel) }
            if row.play.isScoring { scores.append(row.resultLabel) }
            if row.isDriveStart { #expect(row.situationLabel == "Drive start") }
        }
    }
    #expect(handovers.filter { $0 == "Punt" }.count == 9)
    #expect(handovers.filter { $0 == "Intercepted" }.count == 3)
    #expect(handovers.count == 12)
    // Newest drive first: FG, FG, TD, FG, TD.
    #expect(scores == ["FG", "TD", "FG", "FG", "TD"])
    #expect(scores.count == detail.scoringPlayIDs.count)
}

// MARK: - Turnover labels

/// ESPN's 36 is an interception returned for a touchdown. It was filed as a blocked punt.
@Test func aPickSixIsNotABlockedPunt() {
    let play = ladderPlay("p", "(Shotgun) D.Maye pass short middle intended for H.Henry INTERCEPTED by D.Witherspoon at NE 30. D.Witherspoon for 30 yards, TOUCHDOWN.",
                          type: "36", ending: "26", down: 3, score: .touchdown, turnover: true)
    #expect(FieldGeometry.changeOfHandsLabel(for: play) == "Pick-six")
}

/// A punt returned for a score on fourth down is not a failed fourth down, and nor is a
/// blocked kick. "On downs" is for an ordinary snap that came up short.
@Test func onDownsIsOnlyForAFailedFourthDownSnap() {
    let returned = ladderPlay("r", "M.Wishnowsky punts 45 yards to SEA 20, Center-J.Ashby. R.Shaheed for 80 yards, TOUCHDOWN.",
                              type: "34", ending: "26", down: 4, score: .touchdown)
    #expect(FieldGeometry.changeOfHandsLabel(for: returned) == "Punt return")

    let blockedPunt = ladderPlay("b", "M.Wishnowsky punt is BLOCKED by D.Thomas, Center-J.Ashby, RECOVERED by SEA-D.Thomas at NE 20.",
                                 type: "17", ending: "26", down: 4)
    #expect(FieldGeometry.changeOfHandsLabel(for: blockedPunt) == "Punt blocked")

    let blockedKick = ladderPlay("k", "A.Borregales 44 yard field goal is BLOCKED (L.Williams), Center-J.Ashby, Holder-M.Wishnowsky.",
                                 type: "18", ending: "26", down: 4)
    #expect(FieldGeometry.changeOfHandsLabel(for: blockedKick) == "FG blocked")

    let missed = ladderPlay("m", "A.Borregales 52 yard field goal is No Good, Wide Right, Center-J.Ashby, Holder-M.Wishnowsky.",
                            type: "60", ending: "26", down: 4)
    #expect(FieldGeometry.changeOfHandsLabel(for: missed) == "FG missed")

    let shortOfIt = ladderPlay("d", "(Shotgun) D.Maye pass incomplete short left to R.Doubs.",
                               type: "3", ending: "26", down: 4)
    #expect(FieldGeometry.changeOfHandsLabel(for: shortOfIt) == "On downs")

    // ESPN types a fumble on a run as the run.
    let fumble = ladderPlay("f", "R.Stevenson up the middle to NE 30 for 2 yards (E.Jones). FUMBLES (E.Jones), RECOVERED by SEA-J.Love at NE 31.",
                            type: "5", ending: "26", down: 4, turnover: true)
    #expect(FieldGeometry.changeOfHandsLabel(for: fumble) == "Fumble lost")
}

// MARK: - Scoring rows

/// A kickoff returned for a touchdown is the drive, drawn from where it was caught in
/// the returning side's colours — not a marker in the end zone, and not a turnover.
@Test func aKickoffReturnTouchdownIsARowOfItsOwn() throws {
    let kick = ladderPlay("k", "J.Myers kicks 65 yards from SEA 35 to NE 0. K.Williams for 100 yards, TOUCHDOWN.",
                          type: "32", offense: "26", ending: "17", score: .touchdown,
                          from: 65, to: 0, kind: FieldGeometry.classify(
                            typeID: "32", isTurnover: false, start: PlayNode(), end: PlayNode()))
    let drive = ladderDrive([kick], result: "Touchdown", isScore: true)
    let row = try #require(FieldGeometry.rows(for: drive).first)
    #expect(!row.isDriveStart)
    #expect(!row.flipsFrame)
    #expect(row.startX == 0)
    #expect(row.endX == 1)
    #expect(row.situationLabel == "Kick return")
    #expect(row.resultLabel == "TD")
    #expect(drive.offenseScored)
    #expect(!drive.possessionChanges)
}

/// ESPN posts the kick after a touchdown as a play of its own, and can give it the
/// touchdown's scoring type. It is the try, not a second touchdown on the drive.
@Test func aSeparateExtraPointIsNotASecondTouchdown() throws {
    let kick = try JSONDecoder().decode(ESPNPlayDTO.self, from: Data("""
    {"scoringPlay": true, "type": {"id": "61", "text": "Extra Point Good"},
     "scoringType": {"name": "touchdown", "abbreviation": "TD"},
     "text": "J.Myers extra point is GOOD, Center-C.Stoll, Holder-M.Dickson."}
    """.utf8))
    #expect(ESPNMapper.scoreKind(from: kick) == .extraPoint)
    #expect(ScoreKind.extraPoint.label == "XP")

    let summary = try JSONDecoder().decode(ESPNPlayDTO.self, from: Data("""
    {"scoringPlay": true, "scoringType": {"abbreviation": "TD"},
     "text": "(Carson Wentz Pass to Jalen Nailor for Two-Point Conversion)"}
    """.utf8))
    #expect(ESPNMapper.scoreKind(from: summary) == .twoPointConversion)

    // The drive's score is the touchdown, whatever follows it.
    let touchdown = ladderPlay("t", "D.Maye pass short left to E.Raridon for 2 yards, TOUCHDOWN.",
                               score: .touchdown)
    let extra = ladderPlay("x", "A.Borregales extra point is GOOD, Center-J.Ashby, Holder-M.Wishnowsky.",
                           score: .extraPoint)
    let drive = ladderDrive([touchdown, extra], result: "Touchdown", isScore: true)
    #expect(drive.scoringPlay?.id == "t")
    #expect(drive.offenseScored)
}

// MARK: - Drive endings

/// A pick-six is points on the drive, but the other side's: no star, and no "SEA ball"
/// either, since Seattle kicks off next.
@Test func aDriveEndingInAPickSixIsTheOtherSidesScore() {
    let pickSix = ladderPlay("p", "(Shotgun) D.Maye pass short middle intended for H.Henry INTERCEPTED by D.Witherspoon at NE 30. D.Witherspoon for 30 yards, TOUCHDOWN.",
                             type: "36", ending: "26", score: .touchdown, turnover: true)
    let drive = ladderDrive([pickSix], result: "Interception Touchdown", isScore: true)
    #expect(drive.opponentScored)
    #expect(!drive.offenseScored)
    #expect(!drive.possessionChanges)
}

/// After a safety the side that gave it up kicks to the other, so the ball does change
/// hands — and the points are not this side's.
@Test func aSafetyHandsTheBallOver() {
    let safety = ladderPlay("s", "(Shotgun) D.Maye sacked in End Zone for -7 yards, SAFETY (D.Hall).",
                            type: "20", score: .safety, from: 3, to: 100)
    let drive = ladderDrive([safety], result: "Safety")
    #expect(drive.opponentScored)
    #expect(!drive.offenseScored)
    #expect(drive.possessionChanges)
}

/// "Downs" reads like a column header; everywhere a drive's ending is shown, it is the
/// outcome that is shown.
@Test func aFailedFourthDownReadsAsATurnoverOnDowns() {
    let drive = ladderDrive([ladderPlay("d", "(Shotgun) D.Maye pass incomplete short left to R.Doubs.",
                                        type: "3", ending: "26", down: 4)],
                            result: "Downs")
    #expect(drive.outcome == "Turnover on downs")
    #expect(drive.endedInTurnover)
    #expect(drive.possessionChanges)
    #expect(FieldGeometry.rows(for: drive).first?.situationLabel == "On downs")
}
