import Foundation
import Testing
@testable import FootballCore

// MARK: - Builders

private func team(_ abbr: String, id: String, score: Int) -> TeamSide {
    TeamSide(id: id, abbreviation: abbr, displayName: abbr, shortName: abbr, score: score)
}

private func liveGame(
    home: Int = 0,
    away: Int = 0,
    possession: String? = "H",
    redZone: Bool = false,
    lastPlayID: String? = nil,
    lastPlayText: String? = "A play happened",
    turnover: Bool = false,
    down: Int? = 1,
    spot: String? = "HOM 15",
    downDistance: String? = "1st & 10 at HOM 15",
    clock: String = "5:00",
    phase: GamePhase = .live,
    homeAbbr: String = "HOM",
    awayAbbr: String = "AWY"
) -> Game {
    Game(
        id: "G1",
        shortName: "\(awayAbbr) @ \(homeAbbr)",
        phase: phase,
        statusDetail: "",
        period: 3,
        displayClock: clock,
        home: team(homeAbbr, id: "H", score: home),
        away: team(awayAbbr, id: "A", score: away),
        situation: Situation(
            possessionTeamID: possession,
            downDistanceText: downDistance,
            possessionText: spot,
            down: down,
            isRedZone: redZone,
            lastPlayText: lastPlayText,
            lastPlayID: lastPlayID,
            lastPlayWasTurnover: turnover
        )
    )
}

private func snapshot(
    home: Int = 0, away: Int = 0, redZone: Bool = false,
    possession: String? = "H", lastPlayID: String? = nil,
    down: Int? = 1, shortDownDistance: String? = nil, clock: String? = "5:00",
    scoredPlayID: String? = nil, underReview: Bool = false
) -> GameSnapshot {
    GameSnapshot(homeScore: home, awayScore: away, isRedZone: redZone,
                 possessionTeamID: possession, lastPlayID: lastPlayID,
                 down: down, shortDownDistance: shortDownDistance, period: 3, clock: clock,
                 scoredPlayID: scoredPlayID, lastPlayUnderReview: underReview)
}

/// The banner shows one line of each; past these, macOS cuts the key facts off.
private func expectFitsABanner(_ event: AlertEvent, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(event.title.count <= AlertRules.titleLimit, "title: \(event.title)", sourceLocation: sourceLocation)
    #expect((event.subtitle ?? "").count <= AlertRules.subtitleLimit, "subtitle: \(event.subtitle ?? "")", sourceLocation: sourceLocation)
    #expect(event.body.count <= 80, "body: \(event.body)", sourceLocation: sourceLocation)
}

// MARK: - Gating

/// The first time a game is seen there is nothing to compare against, so a game that
/// is already 21–17 at launch must not fire three quarters of backlog.
@Test func firstSightingOfAGameIsSilent() {
    let events = AlertRules.events(previous: nil, game: liveGame(home: 21, away: 17),
                                   settings: AlertSettings())
    #expect(events.isEmpty)
}

@Test func finishedAndUpcomingGamesAreSilent() {
    for phase in [GamePhase.final, .pre] {
        let events = AlertRules.events(
            previous: snapshot(home: 0),
            game: liveGame(home: 7, phase: phase),
            settings: AlertSettings()
        )
        #expect(events.isEmpty, "\(phase) should not alert")
    }
}

@Test func scopeOffSilencesEverything() {
    let events = AlertRules.events(
        previous: snapshot(),
        game: liveGame(home: 7, redZone: true, lastPlayID: "p1", turnover: true),
        settings: AlertSettings(enabled: false)
    )
    #expect(events.isEmpty)
}

@Test func favoritesOnlyFiltersByTeam() {
    let game = liveGame(home: 7)
    let before = snapshot()

    let unrelated = AlertSettings(favoritesOnly: true, favorites: ["KC"])
    #expect(AlertRules.events(previous: before, game: game, settings: unrelated).isEmpty)

    let matching = AlertSettings(favoritesOnly: true, favorites: ["HOM"])
    #expect(!AlertRules.events(previous: before, game: game, settings: matching).isEmpty)
}

@Test func perTypeTogglesAreRespected() {
    let before = snapshot()
    let game = liveGame(home: 7, redZone: true, lastPlayID: "p1", turnover: true)

    let onlyScoring = AlertSettings(scoring: true, turnovers: false, redZone: false)
    let kinds = AlertRules.events(previous: before, game: game, settings: onlyScoring).map(\.kind)
    #expect(kinds == [.scoring])
}

// MARK: - Scoring

/// With no play text to go on, the banner says only what the score proves.
@Test func scoringWithoutUsableTextStaysGeneric() throws {
    let cases: [(Int, String)] = [(7, "TD HOM"), (6, "TD HOM"), (3, "FG HOM"), (2, "HOM +2"), (10, "HOM +10")]
    for (points, title) in cases {
        let event = try #require(AlertRules.scoringEvent(
            previous: snapshot(home: 0),
            game: liveGame(home: points)
        ))
        #expect(event.title == title, "\(points) points")
        #expect(event.kind == .scoring)
    }
}

@Test func scoringCreditsWhicheverSideActuallyScored() throws {
    let event = try #require(AlertRules.scoringEvent(
        previous: snapshot(home: 10, away: 3),
        game: liveGame(home: 10, away: 10)
    ))
    #expect(event.title == "TD AWY")
    // Level scores put the team that just scored first.
    #expect(event.subtitle == "AWY 10–10 HOM · Q3 5:00")
}

@Test func noScoringEventWhenTheScoreIsUnchanged() {
    #expect(AlertRules.scoringEvent(previous: snapshot(home: 7, away: 3),
                                    game: liveGame(home: 7, away: 3)) == nil)
}

@Test func touchdownLeadsWithWhoScoredAndHow() throws {
    let game = liveGame(
        home: 20, away: 0, possession: nil, lastPlayID: "p61",
        lastPlayText: " (Shotgun) J.Goff pass deep middle to A.St. Brown for 19 yards, TOUCHDOWN.",
        homeAbbr: "DET", awayAbbr: "NO"
    )
    let event = try #require(AlertRules.scoringEvent(previous: snapshot(home: 14, lastPlayID: "p60"), game: game))
    #expect(event.title == "TD DET · A. St. Brown 19-yd catch")
    #expect(event.subtitle == "DET 20–0 NO · Q3 5:00")
    #expect(event.body == "From J. Goff")
    expectFitsABanner(event)
}

@Test func rushingTouchdownNeedsNoBody() throws {
    let game = liveGame(home: 30, away: 24, possession: nil, lastPlayID: "p9",
                        lastPlayText: " (Shotgun) C.Williams scrambles left end for 29 yards, TOUCHDOWN.",
                        homeAbbr: "CHI", awayAbbr: "CAR")
    let event = try #require(AlertRules.scoringEvent(previous: snapshot(home: 24, away: 24), game: game))
    #expect(event.title == "TD CHI · C. Williams 29-yd run")
    #expect(event.body.isEmpty)
}

@Test func fieldGoalNamesTheKicker() throws {
    let game = liveGame(home: 3, possession: nil, lastPlayID: "p5",
                        lastPlayText: "A.Borregales 50 yard field goal is GOOD, Center-J.Ashby, Holder-M.Wishnowsky.")
    let event = try #require(AlertRules.scoringEvent(previous: snapshot(), game: game))
    #expect(event.title == "FG HOM · A. Borregales 50 yd")
    #expect(event.body.isEmpty)
}

/// The text must describe a score of the size that landed. Seven points with a field
/// goal as the last play means the touchdown's play has not posted yet.
@Test func mismatchedPlayTextIsNotUsedForNames() throws {
    let game = liveGame(home: 7, lastPlayID: "p5",
                        lastPlayText: "A.Borregales 50 yard field goal is GOOD, Center-J.Ashby, Holder-M.Wishnowsky.")
    let event = try #require(AlertRules.scoringEvent(previous: snapshot(), game: game))
    #expect(event.title == "TD HOM")
}

/// Observed live: the score moved before the next play posted, so the last play on the
/// scoreboard was still a touchdown whose points had already been announced.
@Test func alreadyCreditedPlayIsNotReused() throws {
    let text = " (Shotgun) T.Lawrence pass deep left to J.Meyers for 32 yards, TOUCHDOWN."
    let game = liveGame(home: 13, away: 14, lastPlayID: "td", lastPlayText: text)
    let event = try #require(AlertRules.scoringEvent(
        previous: snapshot(home: 7, away: 14, lastPlayID: "td", scoredPlayID: "td"), game: game))
    #expect(event.title == "TD HOM")
}

/// Observed live in CLE @ JAX and CHI @ CAR: +6 with the touchdown play, then +1 a poll
/// later. That extra point used to be a second banner.
@Test func extraPointAfterTheTouchdownIsFolded() {
    let tdText = " (Shotgun) T.Lawrence pass deep left to J.Meyers for 32 yards, TOUCHDOWN."
    let beforeTD = snapshot(home: 24, away: 0, possession: "H", lastPlayID: "p1")
    let tdPoll = liveGame(home: 30, possession: nil, redZone: true, lastPlayID: "td", lastPlayText: tdText)
    let atTD = AlertRules.events(previous: beforeTD, game: tdPoll, settings: AlertSettings())
    #expect(atTD.map(\.title) == ["TD HOM · J. Meyers 32-yd catch"])

    var snap = GameSnapshot(game: tdPoll, previous: beforeTD)
    // The point lands while the scoreboard still shows the touchdown play…
    let pointPoll = liveGame(home: 31, possession: nil, redZone: true, lastPlayID: "td", lastPlayText: tdText)
    #expect(AlertRules.events(previous: snap, game: pointPoll, settings: AlertSettings()).isEmpty)

    // …and then ESPN posts the kick as its own play.
    snap = GameSnapshot(game: pointPoll, previous: snap)
    let kickPoll = liveGame(home: 31, possession: "H", lastPlayID: "pat", lastPlayText: "(Cam Little Kick)")
    #expect(AlertRules.events(previous: snap, game: kickPoll, settings: AlertSettings()).isEmpty)
}

@Test func successfulTwoPointConversionStillAlerts() throws {
    let game = liveGame(home: 8, possession: nil, lastPlayID: "try",
                        lastPlayText: "(Carson Wentz Pass to Jalen Nailor for Two-Point Conversion)")
    let event = try #require(AlertRules.scoringEvent(previous: snapshot(home: 6, lastPlayID: "td", scoredPlayID: "td"), game: game))
    #expect(event.title == "2-pt good HOM · Jalen Nailor")
}

@Test func safetyIsNotConfusedWithAConversion() throws {
    let safety = liveGame(home: 2, lastPlayID: "s", lastPlayText: "Daron Payne Safety")
    #expect(try #require(AlertRules.scoringEvent(previous: snapshot(), game: safety)).title == "Safety HOM · Daron Payne")

    // Two points with nothing saying which: no guessing.
    let unclear = liveGame(home: 8, lastPlayID: "td", lastPlayText: "J.Gibbs up the middle for 1 yard, TOUCHDOWN.")
    #expect(try #require(AlertRules.scoringEvent(previous: snapshot(home: 6, lastPlayID: "td", scoredPlayID: "td"), game: unclear)).title == "HOM +2")
}

// MARK: - Turnovers

@Test func turnoverFiresOncePerPlay() throws {
    let game = liveGame(lastPlayID: "play-9", turnover: true)
    let event = try #require(AlertRules.turnoverEvent(previous: snapshot(lastPlayID: "play-8"), game: game))
    #expect(event.kind == .turnover)

    // Same play seen again on the next poll: silent.
    #expect(AlertRules.turnoverEvent(previous: snapshot(lastPlayID: "play-9"), game: game) == nil)
}

@Test func ordinaryPlaysAreNotTurnovers() {
    let game = liveGame(lastPlayID: "play-9", turnover: false)
    #expect(AlertRules.turnoverEvent(previous: snapshot(lastPlayID: "play-8"), game: game) == nil)
}

/// Recorded live, CAR @ CHI: possession flipped to CHI in the same payload.
@Test func interceptionSaysWhoPickedItOffAndWhoseBallItIs() throws {
    let game = liveGame(
        home: 31, away: 24, possession: "H", lastPlayID: "int",
        lastPlayText: " (Shotgun) B.Young pass deep left intended for J.Coker INTERCEPTED by M.Muhammad at CHI 38. M.Muhammad to CHI 38 for no gain. CHI-M.Muhammad was injured during the play.",
        turnover: true, spot: "CHI 38", clock: "0:05", homeAbbr: "CHI", awayAbbr: "CAR"
    )
    let event = try #require(AlertRules.turnoverEvent(
        previous: snapshot(home: 31, away: 24, possession: "A", lastPlayID: "p"), game: game))
    #expect(event.title == "INT CHI · M. Muhammad picks off B. Young")
    #expect(event.subtitle == "CHI ball at CHI 38 · CHI 31–24 CAR · Q3 0:05")
    #expect(event.body.isEmpty)
    expectFitsABanner(event)
}

/// ESPN drops possession around kickoffs, so the poll before the first snap often has
/// none. That still counts as the scoreboard having moved.
@Test func interceptionRightAfterAKickoffStillNamesTheTeam() throws {
    let game = liveGame(
        home: 7, possession: "H", lastPlayID: "int",
        lastPlayText: " (Shotgun) T.Shough pass short middle intended for N.Fant INTERCEPTED by D.Barnes at NO 44. D.Barnes to NO 41 for 3 yards (T.Welch).",
        turnover: true, spot: "NO 41", homeAbbr: "DET", awayAbbr: "NO"
    )
    let event = try #require(AlertRules.turnoverEvent(
        previous: snapshot(home: 7, possession: nil, lastPlayID: "kick"), game: game))
    #expect(event.title == "INT DET · D. Barnes picks off T. Shough")
    #expect(event.subtitle?.hasPrefix("DET ball at NO 41") == true)
}

/// Strip-sacks are play type 80, which the scoreboard's turnover flag does not cover.
@Test func fumbleLostIsFoundFromTheText() throws {
    let game = liveGame(
        home: 14, possession: "H", lastPlayID: "ff",
        lastPlayText: "(Shotgun) T.Shough sacked at NO 24 for -7 yards (R.McCreary). FUMBLES (R.McCreary) [R.McCreary], RECOVERED by DET-D.Wonnum at NO 25.",
        turnover: false, spot: "NO 25", clock: "9:45", homeAbbr: "DET", awayAbbr: "NO"
    )
    let event = try #require(AlertRules.turnoverEvent(
        previous: snapshot(home: 14, possession: "A", lastPlayID: "p"), game: game))
    #expect(event.title == "T. Shough fumbles · DET recovers")
    #expect(event.subtitle == "DET ball at NO 25 · DET 14–0 NO · Q3 9:45")
    #expect(event.body == "Strip-sack by R. McCreary · recovered by D. Wonnum")
    expectFitsABanner(event)
}

/// Before the scoreboard catches up, the recovering team comes from the text — which
/// writes Baltimore as "BLT".
@Test func fumbleTeamComesFromTheTextBeforeTheScoreboardUpdates() throws {
    let game = liveGame(
        home: 6, away: 21, possession: "H", lastPlayID: "ff",
        lastPlayText: "(Shotgun) D.Jones pass short left to J.Taylor to IND 48 for 14 yards (M.Humphrey; J.Hawkins). FUMBLES (M.Humphrey), RECOVERED by BLT-M.Humphrey at IND 47.",
        turnover: true, homeAbbr: "IND", awayAbbr: "BAL"
    )
    let event = try #require(AlertRules.turnoverEvent(
        previous: snapshot(home: 6, away: 21, possession: "H", lastPlayID: "p"), game: game))
    #expect(event.title == "J. Taylor fumbles · BAL recovers")
    #expect(event.subtitle == "BAL ball · BAL 21–6 IND · Q3 5:00")
    #expect(event.body == "Forced and recovered by M. Humphrey")
}

/// If the scoreboard and the text disagree about whose ball it is, say neither.
@Test func conflictingPossessionIsLeftUnsaid() throws {
    let game = liveGame(
        possession: "H", lastPlayID: "ff",
        lastPlayText: "(Shotgun) B.Mayfield pass short right to B.Irving to TB 32 for 7 yards (B.Cook) [D.Lawrence]. FUMBLES (B.Cook), RECOVERED by CIN-B.Mafe at TB 33.",
        turnover: true, homeAbbr: "TB", awayAbbr: "CIN"
    )
    let event = try #require(AlertRules.turnoverEvent(
        previous: snapshot(possession: "A", lastPlayID: "p"), game: game))
    #expect(event.title == "Fumble lost · B. Irving")
    #expect(event.subtitle?.contains("ball") == false)
}

@Test func fumbleKeptByTheOffenseIsSilent() {
    let game = liveGame(lastPlayID: "f", lastPlayText: "J.Goff FUMBLES (Aborted) at DET 31, recovered by DET-J.Williams at DET 25. J.Williams to DET 32 for 7 yards (D.Godchaux).")
    #expect(AlertRules.turnoverEvent(previous: snapshot(lastPlayID: "p"), game: game) == nil)
}

@Test func interceptionWipedOutByAPenaltyIsSilent() {
    let game = liveGame(lastPlayID: "x", lastPlayText: "B.Mayfield pass short left intended for E.Egbuka INTERCEPTED by T.Davis at CIN 16. T.Davis ran ob at CIN 20 for 4 yards (E.Egbuka).PENALTY on CIN-T.Davis, Defensive Pass Interference, 12 yards, enforced at CIN 29 - No Play.", turnover: true)
    #expect(AlertRules.turnoverEvent(previous: snapshot(lastPlayID: "p"), game: game) == nil)
}

/// ESPN posts a placeholder while replay looks at a fumble. Announcing it then risks
/// being wrong; the same play is looked at again once the ruling arrives.
@Test func playUnderReviewWaitsForTheRuling() throws {
    let pending = liveGame(possession: "A", lastPlayID: "rev", lastPlayText: "*** play under review ***", turnover: true)
    let before = snapshot(possession: "H", lastPlayID: "p")
    #expect(AlertRules.turnoverEvent(previous: before, game: pending) == nil)

    let afterReview = GameSnapshot(game: pending, previous: before)
    #expect(afterReview.lastPlayUnderReview)
    let ruled = liveGame(
        possession: "A", lastPlayID: "rev",
        lastPlayText: "(Shotgun) C.Stroud sacked at HST 29 for -5 yards (G.Rousseau). FUMBLES (G.Rousseau) [G.Rousseau], RECOVERED by AWY-E.Oliver at HST 32.",
        turnover: true, spot: "HOM 32"
    )
    let event = try #require(AlertRules.turnoverEvent(previous: afterReview, game: ruled))
    #expect(event.title == "C. Stroud fumbles · AWY recovers")
}

/// One banner for a pick-six, carrying both facts.
@Test func pickSixIsASingleAlert() throws {
    let text = "(Shotgun) P.Mahomes pass short middle intended for J.Smith-Schuster INTERCEPTED by D.Lloyd at JAX 1. D.Lloyd for 99 yards, TOUCHDOWN. C.Little extra point is GOOD, Center-R.Matiscik, Holder-L.Cooke."
    let game = liveGame(home: 21, away: 14, possession: nil, lastPlayID: "p6", lastPlayText: text,
                        turnover: true, homeAbbr: "JAX", awayAbbr: "KC")
    let before = snapshot(home: 14, away: 14, possession: "A", lastPlayID: "p5")

    let events = AlertRules.events(previous: before, game: game, settings: AlertSettings())
    #expect(events.count == 1)
    let event = try #require(events.first)
    #expect(event.title == "TD JAX · D. Lloyd 99-yd pick-six")
    #expect(event.body == "Picked off P. Mahomes")
    expectFitsABanner(event)

    // With scoring alerts off, the turnover banner says the same thing, under the same
    // id so the two can never both be delivered.
    let turnoversOnly = AlertRules.events(previous: before, game: game,
                                          settings: AlertSettings(scoring: false, redZone: false))
    #expect(turnoversOnly.map(\.title) == [event.title])
    #expect(turnoversOnly.first?.id == event.id)
}

@Test func turnoverOnDownsSaysWhoGetsTheBall() throws {
    let game = liveGame(
        home: 24, away: 21, possession: "H", lastPlayID: "p4",
        lastPlayText: "(Shotgun) C.Wentz pass incomplete deep middle to J.Addison (D.Elliott).",
        spot: "MIN 32", clock: "0:14", homeAbbr: "PIT", awayAbbr: "MIN"
    )
    let before = snapshot(home: 24, away: 21, possession: "A", lastPlayID: "p3", down: 4,
                          shortDownDistance: "4th & 17", clock: "0:19")
    let event = try #require(AlertRules.turnoverEvent(previous: before, game: game))
    #expect(event.title == "Turnover on downs · PIT ball")
    #expect(event.subtitle == "PIT ball at MIN 32 · PIT 24–21 MIN · Q3 0:14")
    #expect(event.body == "4th & 17 · C. Wentz incomplete to J. Addison")
    expectFitsABanner(event)
}

@Test func puntsAndStaleSnapshotsAreNotTurnoversOnDowns() {
    let punt = liveGame(possession: "H", lastPlayID: "p4",
                        lastPlayText: "M.Wishnowsky punts 38 yards to SEA 14, Center-J.Ashby, fair catch by R.Shaheed.")
    #expect(AlertRules.turnoverEvent(previous: snapshot(possession: "A", lastPlayID: "p3", down: 4), game: punt) == nil)

    // Fourth down twelve minutes of game clock ago — the Mac was asleep, not a stop.
    let later = liveGame(possession: "H", lastPlayID: "p40",
                         lastPlayText: "(Shotgun) C.Wentz pass incomplete deep middle to J.Addison (D.Elliott).", clock: "2:00")
    #expect(AlertRules.turnoverEvent(previous: snapshot(possession: "A", lastPlayID: "p3", down: 4, clock: "14:00"), game: later) == nil)
}

/// ESPN's turnover flag includes missed field goals. Calling one a turnover is wrong.
@Test func missedFieldGoalIsCalledWhatItIs() throws {
    let game = liveGame(
        home: 13, away: 7, possession: "H", lastPlayID: "fg",
        lastPlayText: " N.Folk 45 yard field goal is No Good, Wide Right, Center-L.McCullough, Holder-J.Bailey.",
        turnover: true, spot: "PIT 27", clock: "10:54", homeAbbr: "PIT", awayAbbr: "ATL"
    )
    let event = try #require(AlertRules.turnoverEvent(
        previous: snapshot(home: 13, away: 7, possession: "A", lastPlayID: "p"), game: game))
    #expect(event.title == "ATL missed FG · N. Folk 45 yd")
    #expect(event.subtitle == "PIT ball at PIT 27 · PIT 13–7 ATL · Q3 10:54")
    #expect(event.body == "Wide right")
}

// MARK: - Red zone

@Test func redZoneFiresOnEntryThenStaysQuiet() throws {
    let game = liveGame(home: 7, away: 3, possession: "H", redZone: true, downDistance: "1st & 10 at AWY 12")
    let entering = try #require(AlertRules.redZoneEvent(previous: snapshot(home: 7, away: 3, redZone: false), game: game))
    #expect(entering.kind == .redZone)
    #expect(entering.title == "HOM in the red zone")
    #expect(entering.subtitle == "1st & 10 at AWY 12 · HOM 7–3 AWY · Q3 5:00")
    expectFitsABanner(entering)

    // Still in the red zone on the next snap: no second banner.
    #expect(AlertRules.redZoneEvent(previous: snapshot(home: 7, away: 3, redZone: true, possession: "H"), game: game) == nil)
}

/// A turnover inside the 20 flips who is threatening, which is worth knowing about.
@Test func redZoneReArmsWhenPossessionChanges() throws {
    let game = liveGame(possession: "A", redZone: true)
    let event = try #require(AlertRules.redZoneEvent(
        previous: snapshot(redZone: true, possession: "H"), game: game
    ))
    #expect(event.title == "AWY in the red zone")
}

@Test func noRedZoneEventOutsideTheTwenty() {
    #expect(AlertRules.redZoneEvent(previous: snapshot(redZone: false),
                                    game: liveGame(redZone: false)) == nil)
}

/// Observed on every touchdown and field goal today: while the try or kick is set up
/// ESPN reports the ball inside the 20 with no possession. That used to fire a red zone
/// banner alongside the score, and again after the timeout that follows.
@Test func scoresAndTriesDoNotAnnounceTheRedZone() {
    let tdPoll = liveGame(home: 6, possession: nil, redZone: true, lastPlayID: "td",
                          lastPlayText: "J.Gibbs up the middle for 1 yard, TOUCHDOWN.", down: nil, downDistance: nil)
    let events = AlertRules.events(previous: snapshot(possession: "H", lastPlayID: "p"), game: tdPoll, settings: AlertSettings())
    #expect(events.map(\.kind) == [.scoring])

    let timeout = liveGame(home: 7, possession: nil, redZone: true, lastPlayID: "to",
                           lastPlayText: "Official Timeout at 11:14.", down: nil, downDistance: nil)
    #expect(AlertRules.redZoneEvent(previous: snapshot(home: 7, redZone: false, possession: "H"), game: timeout) == nil)
}

// MARK: - Identity

/// Event ids are the de-duplication key, so two different moments must not collide.
@Test func eventIDsAreDistinctPerMoment() throws {
    let first = try #require(AlertRules.scoringEvent(previous: snapshot(home: 0), game: liveGame(home: 7)))
    let second = try #require(AlertRules.scoringEvent(previous: snapshot(home: 7), game: liveGame(home: 14)))
    #expect(first.id != second.id)
}

// MARK: - A whole recorded game

/// Plays NE @ SEA back one play per poll, the way `--replay` does, and holds every banner
/// to the banner limits. The game had five scores and three interceptions; each must
/// produce exactly one banner that names the player.
@Test func replayingARecordedGameGivesOneNamedBannerPerMoment() throws {
    let url = try #require(Bundle.module.url(forResource: "summary", withExtension: "json", subdirectory: "Fixtures"))
    let dto = try JSONDecoder().decode(ESPNSummaryDTO.self, from: Data(contentsOf: url))
    let detail = ESPNMapper.detail(from: dto, gameID: "401872656")
    let plays = detail.drives.reversed().flatMap(\.plays)

    var previous: GameSnapshot?
    var home = 0, away = 0
    var events: [AlertEvent] = []
    for play in plays {
        if let h = play.homeScore, let a = play.awayScore { (home, away) = (h, a) }
        let admin = play.kind == .administrative
        let toEndzone = play.end.yardsToEndzone ?? 100
        let game = Game(
            id: "401872656", shortName: "NE @ SEA", phase: .live, statusDetail: "",
            period: play.period, displayClock: play.clock,
            home: team("SEA", id: "26", score: home),
            away: team("NE", id: "17", score: away),
            situation: Situation(
                possessionTeamID: admin ? nil : play.end.teamID,
                downDistanceText: play.downDistanceText,
                down: play.end.down,
                isRedZone: !admin && toEndzone > 0 && toEndzone <= 20,
                lastPlayText: play.text, lastPlayID: play.id, lastPlayTypeID: play.typeID,
                lastPlayWasTurnover: play.typeID.map(FieldGeometry.turnoverTypeIDs.contains) ?? false
            )
        )
        events += AlertRules.events(previous: previous, game: game, settings: AlertSettings())
        previous = GameSnapshot(game: game, previous: previous)
    }

    for event in events { expectFitsABanner(event) }
    #expect(events.filter { $0.kind == .scoring }.map(\.title) == [
        "TD NE · E. Raridon 2-yd catch",
        "FG NE · A. Borregales 50 yd",
        "FG SEA · J. Myers 30 yd",
        "TD SEA · J. Smith-Njigba 45-yd catch",
        "FG SEA · J. Myers 26 yd",
    ])
    #expect(events.filter { $0.kind == .turnover }.map(\.title) == [
        "INT SEA · N. Pritchett picks off D. Maye",
        "INT SEA · J. Love picks off D. Maye",
        "INT SEA · J. Jobe picks off D. Maye",
    ])
}
