import Foundation
import Testing
@testable import FootballCore

// Every string here is verbatim ESPN play text: from the recorded NE @ SEA game in
// Fixtures/summary.json, from the live scoreboard on 2026-09-13, or from 2025 summaries.
// Leading spaces and line breaks are ESPN's own.

// MARK: - Touchdowns

@Test func passingTouchdownNamesTheCatcherAndThePasser() {
    let play = PlaySummary.parse(
        "D.Lock pass short left to J.Smith-Njigba for 45 yards, TOUCHDOWN. J.Myers extra point is GOOD, Center-C.Stoll, Holder-M.Dickson."
    )
    #expect(play.kind == .pass)
    #expect(play.touchdown == .pass)
    #expect(play.scorer == "J. Smith-Njigba")
    #expect(play.passer == "D. Lock")
    #expect(play.yards == 45)
    #expect(play.tryResult == .extraPointGood)
    #expect(play.takeaway == nil)
}

/// "Reported in as eligible" names a lineman, and "Van Roten" has a space in it; neither
/// may be taken for the passer.
@Test func eligibilityNoticeIsNotThePlay() {
    let play = PlaySummary.parse(
        "G.Van Roten reported in as eligible.  D.Maye pass short left to E.Raridon for 2 yards, TOUCHDOWN. A.Borregales extra point is GOOD, Center-J.Ashby, Holder-M.Wishnowsky."
    )
    #expect(play.scorer == "E. Raridon")
    #expect(play.passer == "D. Maye")
    #expect(play.yards == 2)
}

@Test func rushingTouchdownFromTheLiveScoreboard() {
    let play = PlaySummary.parse(" (Shotgun) C.Williams scrambles left end for 29 yards, TOUCHDOWN.")
    #expect(play.kind == .rush)
    #expect(play.touchdown == .rush)
    #expect(play.scorer == "C. Williams")
    #expect(play.yards == 29)
    #expect(play.tryResult == nil)
}

/// The live feed broke this one across two lines and led with the game clock.
@Test func toleratesALineBreakAndAClockPrefix() {
    let play = PlaySummary.parse("(9:44) B.Hall left end for 4 yards, TOUCHDOWN.\nPenalty on TEN, Defensive Too Many Men on Field, declined.")
    #expect(play.touchdown == .rush)
    #expect(play.scorer == "B. Hall")
    #expect(play.yards == 4)
}

@Test func namesWithPrefixesAndShortenedInitials() {
    let stBrown = PlaySummary.parse(" (Shotgun) J.Goff pass deep middle to A.St. Brown for 19 yards, TOUCHDOWN.")
    #expect(stBrown.scorer == "A. St. Brown")

    // ESPN widens the initial to tell two Robinsons apart.
    let bijan = PlaySummary.parse("(Shotgun) C.Rush pass short right to Bi.Robinson for 23 yards, TOUCHDOWN. N.Folk extra point is GOOD, Center-L.McCullough, Holder-J.Bailey.")
    #expect(bijan.scorer == "Bi. Robinson")

    #expect(PlaySummary.display("H.To'oTo'o") == "H. To'oTo'o")
    #expect(PlaySummary.display("Jaxon Smith-Njigba") == "Jaxon Smith-Njigba")
}

@Test func missedExtraPointIsReadOffTheEnd() {
    let play = PlaySummary.parse("J.Taylor right end for 1 yard, TOUCHDOWN. S.Shrader extra point is No Good, Wide Right, Center-L.Rhodes, Holder-R.Sanchez.")
    #expect(play.scorer == "J. Taylor")
    #expect(play.tryResult == .extraPointMissed)
}

/// The two-point pass must not be mistaken for the touchdown pass in front of it.
@Test func twoPointConversionAfterTheTouchdown() {
    let play = PlaySummary.parse("M.Jones pass short right to J.Tonges for 2 yards, TOUCHDOWN. TWO-POINT CONVERSION ATTEMPT. M.Jones pass to D.Robinson is complete. ATTEMPT SUCCEEDS.")
    #expect(play.scorer == "J. Tonges")
    #expect(play.tryResult == .twoPointGood)
}

// MARK: - Kicks

@Test func fieldGoalNamesKickerAndDistance() {
    let play = PlaySummary.parse("A.Borregales 50 yard field goal is GOOD, Center-J.Ashby, Holder-M.Wishnowsky.")
    #expect(play.kind == .fieldGoal(.good))
    #expect(play.scorer == "A. Borregales")
    #expect(play.yards == 50)
}

@Test func missedFieldGoalKeepsTheReason() {
    let play = PlaySummary.parse(" N.Folk 45 yard field goal is No Good, Wide Right, Center-L.McCullough, Holder-J.Bailey.")
    #expect(play.kind == .fieldGoal(.missed))
    #expect(play.kicker == "N. Folk")
    #expect(play.detail == "Wide Right")
    #expect(play.scorer == nil)
    #expect(play.takeaway == nil)
}

/// The scoreboard posts the try as its own play, in scoring-summary style with full names.
@Test func liveTryPlaysUseFullNames() {
    let kick = PlaySummary.parse("(Cairo Santos Kick)")
    #expect(kick.kind == .extraPoint(good: true))
    #expect(kick.kicker == "Cairo Santos")

    let conversion = PlaySummary.parse("(Carson Wentz Pass to Jalen Nailor for Two-Point Conversion)")
    #expect(conversion.kind == .twoPointConversion(good: true))
    #expect(conversion.scorer == "Jalen Nailor")
    #expect(conversion.passer == "Carson Wentz")

    #expect(PlaySummary.parse("(Two-Point Pass Conversion Failed)").kind == .twoPointConversion(good: false))
    #expect(PlaySummary.parse("(Harrison Butker PAT Failed)").kind == .extraPoint(good: false))

    let safety = PlaySummary.parse("Daron Payne Safety")
    #expect(safety.kind == .safety)
    #expect(safety.scorer == "Daron Payne")
}

@Test func scoringSummaryLines() {
    let pass = PlaySummary.parse("Jaxon Smith-Njigba 45 Yd pass from Drew Lock (Jason Myers Kick)")
    #expect(pass.touchdown == .pass)
    #expect(pass.scorer == "Jaxon Smith-Njigba")
    #expect(pass.passer == "Drew Lock")
    #expect(pass.yards == 45)

    let pick = PlaySummary.parse("Kenny Moore II 32 Yd Interception Return (Spencer Shrader Kick)")
    #expect(pick.touchdown == .interceptionReturn)
    #expect(pick.scorer == "Kenny Moore II")

    // Could be either side falling on it, so no takeaway is claimed.
    let recovery = PlaySummary.parse("Tyler Lockett 0 Yd Fumble Recovery (Joey Slye Kick)")
    #expect(recovery.touchdown == .fumbleRecovery)
    #expect(recovery.takeaway == nil)
}

// MARK: - Turnovers

@Test func interceptionNamesBothPlayers() {
    let play = PlaySummary.parse("D.Maye pass deep left intended for R.Doubs INTERCEPTED by N.Pritchett (R.Thomas) at SEA 3. N.Pritchett to SEA 33 for 30 yards (J.Wilson).")
    #expect(play.kind == .interception)
    #expect(play.takeaway == .interception)
    #expect(play.recoveredBy == "N. Pritchett")
    #expect(play.passer == "D. Maye")
    #expect(play.receiver == "R. Doubs")
    #expect(play.returnYards == 30)
    // Interceptions do not name a team; the scoreboard has to say whose ball it is.
    #expect(play.recoveringTeam == nil)
}

@Test func interceptionForATouchback() {
    let play = PlaySummary.parse("(Shotgun) D.Maye pass deep right intended for M.Hollins INTERCEPTED by J.Jobe [D.Lawrence] at SEA -3. Touchback.")
    #expect(play.takeaway == .interception)
    #expect(play.recoveredBy == "J. Jobe")
    #expect(play.returnYards == nil)
}

@Test func pickSixIsOnePlayWithBothFacts() {
    let play = PlaySummary.parse("(Shotgun) P.Mahomes pass short middle intended for J.Smith-Schuster INTERCEPTED by D.Lloyd at JAX 1. D.Lloyd for 99 yards, TOUCHDOWN. C.Little extra point is GOOD, Center-R.Matiscik, Holder-L.Cooke.")
    #expect(play.takeaway == .interception)
    #expect(play.touchdown == .interceptionReturn)
    #expect(play.scorer == "D. Lloyd")
    #expect(play.passer == "P. Mahomes")
    #expect(play.returnYards == 99)
}

@Test func fumbleLostNamesWhoLostItAndWhoGotIt() {
    let play = PlaySummary.parse("(Shotgun) B.Mayfield pass short right to B.Irving to TB 32 for 7 yards (B.Cook) [D.Lawrence]. FUMBLES (B.Cook), RECOVERED by CIN-B.Mafe at TB 33.")
    #expect(play.kind == .pass)
    #expect(play.takeaway == .fumble)
    // The receiver had the ball, not the quarterback named first.
    #expect(play.fumbledBy == "B. Irving")
    #expect(play.forcedBy == "B. Cook")
    #expect(play.recoveredBy == "B. Mafe")
    #expect(play.recoveringTeam == "CIN")
}

@Test func stripSackRecoveredByTheDefense() {
    let play = PlaySummary.parse("(Shotgun) T.Shough sacked at NO 24 for -7 yards (R.McCreary). FUMBLES (R.McCreary) [R.McCreary], RECOVERED by DET-D.Wonnum at NO 25.")
    #expect(play.kind == .sack)
    #expect(play.takeaway == .fumble)
    #expect(play.fumbledBy == "T. Shough")
    #expect(play.recoveringTeam == "DET")
}

/// Lower-case "recovered by" is the gamebook's way of saying the offense kept it.
@Test func fumbleRecoveredByTheSameTeamIsNotATurnover() {
    let aborted = PlaySummary.parse("J.Goff FUMBLES (Aborted) at DET 31, recovered by DET-J.Williams at DET 25. J.Williams to DET 32 for 7 yards (D.Godchaux).")
    #expect(aborted.takeaway == nil)
    #expect(aborted.fumbledBy == "J. Goff")

    let fellOnIt = PlaySummary.parse("(Shotgun) G.Smith FUMBLES (Aborted) at NYJ 19, and recovers at NYJ 18.")
    #expect(fellOnIt.takeaway == nil)
}

@Test func fumbleReturnedForATouchdown() {
    let play = PlaySummary.parse("(No Huddle) B.Mayfield sacked at TB 25 for -8 yards (sack split by M.Murphy and B.Carter). FUMBLES (M.Murphy) [B.Carter], touched at TB 26, RECOVERED by CIN-D.Knight at TB 27. D.Knight for 27 yards, TOUCHDOWN. E.McPherson extra point is GOOD, Center-W.Wagner, Holder-R.Rehkow.")
    #expect(play.takeaway == .fumble)
    #expect(play.touchdown == .fumbleReturn)
    #expect(play.scorer == "D. Knight")
    #expect(play.fumbledBy == "B. Mayfield")
    #expect(play.returnYards == 27)
}

@Test func playTextAbbreviatesSomeTeamsItsOwnWay() {
    let play = PlaySummary.parse("(Shotgun) D.Jones pass short left to J.Taylor to IND 48 for 14 yards (M.Humphrey; J.Hawkins). FUMBLES (M.Humphrey), RECOVERED by BLT-M.Humphrey at IND 47.")
    #expect(play.recoveringTeam == "BLT")
    #expect(PlaySummary.scoreboardAbbreviation("BLT") == "BAL")
    #expect(PlaySummary.scoreboardAbbreviation("SEA") == "SEA")
}

@Test func muffedPuntRecoveredByTheKickingTeam() {
    let play = PlaySummary.parse("(7:07) T.Taylor punts 48 yards to CAR 22, Center-B.Gardner. Ji.Horn MUFFS catch, RECOVERED by CHI-K.Davis at CAR 28.")
    #expect(play.kind == .punt)
    #expect(play.takeaway == .muffedKick)
    #expect(play.fumbledBy == "Ji. Horn")
    #expect(play.recoveringTeam == "CHI")
}

/// Capital "RECOVERED" with nothing loose before it: the kicking team kept its own
/// onside kick, which is not a takeaway.
@Test func recoveredOnsideKickIsNotATakeaway() {
    let play = PlaySummary.parse("S.Martin kicks onside 14 yards from CAR 35 to CAR 49, impetus ends at CAR 44. RECOVERED by CAR-D.Richardson.")
    #expect(play.kind == .kickoff)
    #expect(play.takeaway == nil)
}

/// Picked off, then fumbled, and the intercepting side fell on it: still one change of
/// hands, and it is still an interception.
@Test func interceptionFumbledButKept() {
    let play = PlaySummary.parse("(Shotgun) C.Stroud pass deep right intended for J.Noel INTERCEPTED by D.Lenoir at SF 44. D.Lenoir to HST 30 for 26 yards (L.Tomlinson). FUMBLES (L.Tomlinson), recovered by SF-M.Williams at HST 30.")
    #expect(play.takeaway == .interception)
    #expect(play.recoveredBy == "D. Lenoir")
}

// MARK: - Plays that did not happen

@Test func penaltyNullifiedTouchdownIsNoPlay() {
    let play = PlaySummary.parse("(Shotgun) D.Lock pass short left to C.Kupp for 7 yards, TOUCHDOWN NULLIFIED by Penalty.PENALTY on SEA, Illegal Shift, 5 yards, enforced at NE 7 - No Play.")
    #expect(play.kind == .noPlay)
    #expect(play.touchdown == nil)
    #expect(play.scorer == nil)
}

@Test func interceptionWipedOutByAFlagIsNoPlay() {
    let play = PlaySummary.parse("B.Mayfield pass short left intended for E.Egbuka INTERCEPTED by T.Davis at CIN 16. T.Davis ran ob at CIN 20 for 4 yards (E.Egbuka).PENALTY on CIN-T.Davis, Defensive Pass Interference, 12 yards, enforced at CIN 29 - No Play.")
    #expect(play.kind == .noPlay)
    #expect(play.takeaway == nil)
}

/// A safety enforced by penalty still scores, even though it says "No Play".
@Test func safetyByPenaltyStillCounts() {
    let play = PlaySummary.parse("(Shotgun) M.Jones sacked at SF 6 for 0 yards (Ma.Wilson).PENALTY on SF-D.Puni, Offensive Holding, 6 yards, enforced in End Zone, SAFETY - No Play.")
    #expect(play.kind == .safety)
}

@Test func replayReversalUsesOnlyTheCorrectedPlay() {
    let overturned = PlaySummary.parse("(Shotgun) L.Jackson pass deep left to D.Hopkins for 42 yards, TOUCHDOWN.The Replay Official reviewed the runner broke the plane ruling, and the play was REVERSED.(Shotgun) L.Jackson pass deep left to D.Hopkins to CLV 1 for 41 yards (G.Newsome).")
    #expect(overturned.touchdown == nil)
    #expect(overturned.kind == .pass)
    #expect(overturned.yards == 41)

    let awarded = PlaySummary.parse("(Shotgun) J.Goff pass incomplete short left to I.TeSlaa.The Replay Official reviewed the incomplete pass ruling, and the play was REVERSED.(Shotgun) J.Goff pass short left to I.TeSlaa for 13 yards, TOUCHDOWN. J.Bates extra point is GOOD, Center-H.Hatten, Holder-J.Fox.")
    #expect(awarded.touchdown == .pass)
    #expect(awarded.scorer == "I. TeSlaa")

    let fumbleUndone = PlaySummary.parse("J.Mason left end to PIT 38 for 7 yards (C.Clark). FUMBLES (C.Clark), RECOVERED by PIT-J.Ramsey at PIT 38. J.Ramsey for 62 yards, TOUCHDOWN.The Replay Official reviewed the ball was inbounds ruling, and the play was REVERSED.J.Mason left end to PIT 38 for 7 yards (C.Clark). FUMBLES (C.Clark), ball out of bounds at PIT 38.")
    #expect(fumbleUndone.takeaway == nil)
    #expect(fumbleUndone.touchdown == nil)
}

/// When only the try was reviewed, the touchdown in front of it still stands.
@Test func reversalOfTheTryKeepsTheTouchdown() {
    let play = PlaySummary.parse("(Shotgun) B.Hall right end for 27 yards, TOUCHDOWN. TWO-POINT CONVERSION ATTEMPT. J.Fields pass to I.Davis is complete. ATTEMPT FAILS.The Replay Official reviewed the short of the goal line ruling, and the play was REVERSED.TWO-POINT CONVERSION ATTEMPT. J.Fields pass to I.Davis is complete. ATTEMPT SUCCEEDS.")
    #expect(play.scorer == "B. Hall")
    #expect(play.tryResult == .twoPointGood)
}

@Test func reviewPlaceholderIsRecognised() {
    #expect(PlaySummary.parse("*** play under review ***").kind == .underReview)
    #expect(PlaySummary.parse(nil).kind == .unknown)
    #expect(PlaySummary.parse("END QUARTER 2").kind == .unknown)
}

// MARK: - Matching players

@Test func displayNamesMatchRosterNames() {
    #expect(PlaySummary.name("J. Chase", matchesFirst: "Ja'Marr", last: "Chase"))
    #expect(PlaySummary.name("A. St. Brown", matchesFirst: "Amon-Ra", last: "St. Brown"))
    #expect(PlaySummary.name("Bi. Robinson", matchesFirst: "Bijan", last: "Robinson"))
    #expect(!PlaySummary.name("Bi. Robinson", matchesFirst: "Brian", last: "Robinson Jr."))
    #expect(PlaySummary.name("M. Muhammad", matchesFirst: "Malik", last: "Muhammad II"))
    #expect(PlaySummary.name("Jalen Nailor", matchesFirst: "Jalen", last: "Nailor"))
    #expect(!PlaySummary.name("J. Chase", matchesFirst: "Ja'Marr", last: "Chasen"))
}

// MARK: - A whole recorded game

/// Every scoring play in the recorded game must yield the scorer ESPN's own scoring
/// summary names, and only the plays ESPN marks as turnovers may parse as takeaways.
@Test func agreesWithESPNAcrossARecordedGame() throws {
    let url = try #require(Bundle.module.url(forResource: "summary", withExtension: "json", subdirectory: "Fixtures"))
    let dto = try JSONDecoder().decode(ESPNSummaryDTO.self, from: Data(contentsOf: url))
    let drives = (dto.drives?.previous ?? []).compacted()
    let plays = drives.flatMap { ($0.plays ?? []).compacted() }
    #expect(plays.count > 150)

    let summaries = Dictionary(uniqueKeysWithValues: (dto.scoringPlays ?? []).compacted()
        .compactMap { play in play.id.map { ($0, play.text ?? "") } })
    #expect(summaries.count == 5)

    for play in plays {
        let parsed = PlaySummary.parse(play.text)
        #expect(parsed.isTurnover == (play.isTurnover ?? false), "\(play.text ?? "")")

        if let id = play.id, let official = summaries[id] {
            let scorer = try #require(parsed.scorer, "no scorer in \(play.text ?? "")")
            let surname = scorer.split(separator: " ").last.map(String.init) ?? scorer
            #expect(official.contains(surname), "\(scorer) vs \(official)")
        } else {
            #expect(parsed.touchdown == nil, "\(play.text ?? "")")
            #expect(parsed.kind != .fieldGoal(.good), "\(play.text ?? "")")
        }
    }
}
