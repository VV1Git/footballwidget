import Foundation
import Testing
@testable import FootballCore

// Per-play fantasy points, worked out from the play feed. The whole-game checks run the
// recorded NE @ SEA feed (Fixtures/summary.json, week 1 2026) against ESPN's own week-1
// totals for the same players, from the league fixtures recorded in the same week.

// MARK: - Builders

private func scoringPlayer(
    _ id: Int, _ first: String, _ last: String, _ position: FantasyPosition = .wideReceiver,
    team: Int = 26
) -> RosterPlayer {
    RosterPlayer(id: id, fullName: "\(first) \(last)", firstName: first, lastName: last,
                 position: position, slot: .starting(position.rawValue), proTeamID: team,
                 points: 0, injuryStatus: nil)
}

private func scoringSnap(_ id: String, _ text: String, offense: String? = "26",
                         score: ScoreKind? = nil) -> Play {
    Play(id: id, sequence: 0, typeID: nil, typeText: "", text: text,
         downDistanceText: nil, yards: 0, period: 2, clock: "7:15",
         isScoring: score != nil, scoreKind: score, isTurnover: false, isPenalty: false,
         start: PlayNode(teamID: offense), end: PlayNode(), kind: .scrimmage)
}

/// Plays given oldest first, as one drive, the way ESPN's feed maps a game.
private func scoringFeed(_ plays: [Play]) -> GameDetail {
    let drive = Drive(id: "d", teamID: "26", teamAbbreviation: "SEA", result: "",
                      isScore: false, yards: 0, playCount: plays.count, timeElapsed: "",
                      summary: "", startText: nil, plays: plays, isCurrent: true)
    return GameDetail(gameID: "401872656", drives: [drive], scoringPlayIDs: [])
}

private let neAtSea = Game(
    id: "401872656", shortName: "NE @ SEA", phase: .final, statusDetail: "Final",
    period: 4, displayClock: "0:00",
    home: TeamSide(id: "26", abbreviation: "SEA", displayName: "Seattle Seahawks",
                   shortName: "Seahawks", score: 13),
    away: TeamSide(id: "17", abbreviation: "NE", displayName: "New England Patriots",
                   shortName: "Patriots", score: 10)
)

/// The scoring both of the user's leagues use, as read off the live recording and
/// confirmed by the whole-game totals below: 0.04 a passing yard, 4 a passing
/// touchdown, -2 an interception, a tenth of a point a rushing or receiving yard, 6 a
/// touchdown, a point a catch. The kicking and defense values are ESPN's defaults.
private let recordedRules = FantasyScoringRules(points: [
    FantasyStat.passingYards: 0.04, FantasyStat.passingTouchdowns: 4,
    FantasyStat.interceptionsThrown: -2, FantasyStat.passingTwoPointConversions: 2,
    FantasyStat.rushingYards: 0.1, FantasyStat.rushingTouchdowns: 6,
    FantasyStat.rushingTwoPointConversions: 2,
    FantasyStat.receivingYards: 0.1, FantasyStat.receivingTouchdowns: 6,
    FantasyStat.receptions: 1, FantasyStat.receivingTwoPointConversions: 2,
    FantasyStat.fumblesLost: -2,
    FantasyStat.fieldGoalsMadeUnder40: 3, FantasyStat.fieldGoalsMade40To49: 4,
    FantasyStat.fieldGoalsMade50To59: 5, FantasyStat.fieldGoalsMade60Plus: 6,
    FantasyStat.fieldGoalsMissed: -1, FantasyStat.extraPointsMade: 1,
    FantasyStat.extraPointsMissed: -1,
    FantasyStat.defensiveSacks: 1, FantasyStat.defensiveInterceptions: 2,
    FantasyStat.defensiveFumbleRecoveries: 2, FantasyStat.defensiveSafeties: 2,
    FantasyStat.defensiveBlockedKicks: 2,
    FantasyStat.kickoffReturnTouchdowns: 6, FantasyStat.puntReturnTouchdowns: 6,
    FantasyStat.interceptionReturnTouchdowns: 6, FantasyStat.fumbleReturnTouchdowns: 6,
    FantasyStat.blockedKickReturnTouchdowns: 6,
])

private func scoringFixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json",
                                             subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private func recordedGame() throws -> GameDetail {
    let dto = try JSONDecoder().decode(ESPNSummaryDTO.self, from: scoringFixture("summary"))
    return ESPNMapper.detail(from: dto, gameID: "401872656")
}

/// ESPN's week-1 points for a player, from a league fixture recorded that week.
private func espnWeekOnePoints(_ playerID: Int, in fixture: String) throws -> Double {
    let league = try JSONDecoder().decode(FantasyLeagueDTO.self, from: scoringFixture(fixture))
    let players = (league.teams ?? []).compacted()
        .flatMap { ($0.roster?.entries ?? []).compacted() }
        .compactMap { $0.playerPoolEntry?.player }
    let player = try #require(players.first { $0.id == playerID })
    let line = (player.stats ?? []).compacted().first {
        $0.statSourceId == 0 && $0.scoringPeriodId == 1
    }
    return try #require(line?.appliedTotal)
}

private func gameTotal(_ player: RosterPlayer, _ scorer: FantasyGameScorer,
                       rules: FantasyScoringRules = recordedRules) -> Double {
    let total = scorer.lines(for: player).reduce(0.0) {
        $0 + rules.points(for: $1.stats, position: player.position)
    }
    return (total * 100).rounded() / 100
}

private func statTotal(_ stat: Int, _ player: RosterPlayer, _ scorer: FantasyGameScorer) -> Double {
    scorer.lines(for: player).reduce(0.0) { $0 + $1.stats[stat] }
}

private let maye = scoringPlayer(4431452, "Drake", "Maye", .quarterback, team: 17)
private let smithNjigba = scoringPlayer(4430878, "Jaxon", "Smith-Njigba")
private let shaheed = scoringPlayer(4032473, "Rashid", "Shaheed")
private let henderson = scoringPlayer(4432710, "TreVeyon", "Henderson", .runningBack, team: 17)

// MARK: - The whole game against ESPN

/// The check that matters: every play of a real game scored on its own, added up, comes
/// to what ESPN credited for the week. Maye's 9.82 covers passing yards, a touchdown
/// pass, three interceptions, scrambles and three sacks that score nothing; Smith-Njigba's
/// 26.2 covers eight catches, 122 yards and a 45-yard touchdown.
@Test func perPlayPointsAddUpToESPNsWeekForTheRecordedGame() throws {
    let scorer = FantasyGameScorer(detail: try recordedGame(), game: neAtSea)

    let mayeESPN = try espnWeekOnePoints(maye.id, in: "league-winprob")
    #expect(mayeESPN == 9.82)
    #expect(abs(gameTotal(maye, scorer) - mayeESPN) < 0.1)

    let jsnESPN = try espnWeekOnePoints(smithNjigba.id, in: "league-betweenweeks")
    #expect(jsnESPN == 26.2)
    #expect(abs(gameTotal(smithNjigba, scorer) - jsnESPN) < 0.1)

    let shaheedESPN = try espnWeekOnePoints(shaheed.id, in: "league-betweenweeks")
    #expect(abs(gameTotal(shaheed, scorer) - shaheedESPN) < 0.1)

    // Rostered, did not play: nothing anywhere.
    #expect(try espnWeekOnePoints(henderson.id, in: "league-betweenweeks") == 0)
    #expect(gameTotal(henderson, scorer) == 0)
}

/// The same game against its box score, stat by stat, for everyone who touched the
/// ball — a wider net for the parser than the three players with fantasy totals.
@Test func perPlayStatsAddUpToTheRecordedBoxScore() throws {
    let scorer = FantasyGameScorer(detail: try recordedGame(), game: neAtSea)

    // Passing: C/ATT, yards, TD, INT, sacks.
    let lock = scoringPlayer(3924327, "Drew", "Lock", .quarterback)
    let darnold = scoringPlayer(3912547, "Sam", "Darnold", .quarterback)
    for (qb, line) in [(maye, [23, 33, 178, 1, 3, 3]), (lock, [16, 22, 187, 1, 0, 1]),
                       (darnold, [1, 2, 13, 0, 0, 1])] {
        #expect(statTotal(FantasyStat.passCompletions, qb, scorer) == Double(line[0]), "\(qb.fullName)")
        #expect(statTotal(FantasyStat.passAttempts, qb, scorer) == Double(line[1]), "\(qb.fullName)")
        #expect(statTotal(FantasyStat.passingYards, qb, scorer) == Double(line[2]), "\(qb.fullName)")
        #expect(statTotal(FantasyStat.passingTouchdowns, qb, scorer) == Double(line[3]), "\(qb.fullName)")
        #expect(statTotal(FantasyStat.interceptionsThrown, qb, scorer) == Double(line[4]), "\(qb.fullName)")
        #expect(statTotal(FantasyStat.timesSacked, qb, scorer) == Double(line[5]), "\(qb.fullName)")
    }

    // Rushing: carries, yards.
    let rushing: [(RosterPlayer, Int, Int)] = [
        (scoringPlayer(4569173, "Rhamondre", "Stevenson", .runningBack, team: 17), 18, 51),
        (maye, 7, 47),
        (scoringPlayer(4431431, "Corey", "Kiner", .runningBack, team: 17), 6, 11),
        (scoringPlayer(4685512, "Jadarian", "Price", .runningBack), 10, 52),
        (scoringPlayer(4429835, "George", "Holani", .runningBack), 8, 29),
        (lock, 2, 13),
        (scoringPlayer(4887558, "Emanuel", "Wilson", .runningBack), 2, 3),
    ]
    for (runner, carries, yards) in rushing {
        #expect(statTotal(FantasyStat.rushAttempts, runner, scorer) == Double(carries), "\(runner.fullName)")
        #expect(statTotal(FantasyStat.rushingYards, runner, scorer) == Double(yards), "\(runner.fullName)")
    }

    // Receiving: catches, yards, touchdowns, targets.
    let receiving: [(RosterPlayer, Int, Int, Int, Int)] = [
        (scoringPlayer(2991662, "Mack", "Hollins", team: 17), 4, 51, 0, 5),
        (scoringPlayer(4569173, "Rhamondre", "Stevenson", .runningBack, team: 17), 5, 44, 0, 6),
        (scoringPlayer(3046439, "Hunter", "Henry", .tightEnd, team: 17), 3, 26, 0, 3),
        (scoringPlayer(4047646, "A.J.", "Brown", team: 17), 3, 26, 0, 4),
        (scoringPlayer(4427095, "DeMario", "Douglas", team: 17), 5, 20, 0, 7),
        (scoringPlayer(4831959, "Eli", "Raridon", .tightEnd, team: 17), 1, 2, 1, 1),
        (smithNjigba, 8, 122, 1, 11),
        (scoringPlayer(2977187, "Cooper", "Kupp"), 2, 35, 0, 3),
        (shaheed, 1, 4, 0, 3),
    ]
    for (receiver, catches, yards, touchdowns, targets) in receiving {
        #expect(statTotal(FantasyStat.receptions, receiver, scorer) == Double(catches), "\(receiver.fullName)")
        #expect(statTotal(FantasyStat.receivingYards, receiver, scorer) == Double(yards), "\(receiver.fullName)")
        #expect(statTotal(FantasyStat.receivingTouchdowns, receiver, scorer) == Double(touchdowns), "\(receiver.fullName)")
        #expect(statTotal(FantasyStat.targets, receiver, scorer) == Double(targets), "\(receiver.fullName)")
    }

    // Kicking: Myers 2/2 from 30 and 26 and an extra point; Borregales a 50-yarder and one.
    let myers = scoringPlayer(2473037, "Jason", "Myers", .kicker)
    let borregales = scoringPlayer(4569923, "Andy", "Borregales", .kicker, team: 17)
    #expect(statTotal(FantasyStat.fieldGoalsMadeUnder40, myers, scorer) == 2)
    #expect(statTotal(FantasyStat.extraPointsMade, myers, scorer) == 1)
    #expect(gameTotal(myers, scorer) == 7)
    #expect(statTotal(FantasyStat.fieldGoalsMade50To59, borregales, scorer) == 1)
    #expect(statTotal(FantasyStat.fieldGoalsMade50Plus, borregales, scorer) == 1)
    #expect(gameTotal(borregales, scorer) == 6)

    // Defenses: Seattle three sacks and three picks, New England two sacks.
    let seattle = scoringPlayer(-16026, "Seahawks", "D/ST", .defense, team: 26)
    let newEngland = scoringPlayer(-16017, "Patriots", "D/ST", .defense, team: 17)
    #expect(statTotal(FantasyStat.defensiveSacks, seattle, scorer) == 3)
    #expect(statTotal(FantasyStat.defensiveInterceptions, seattle, scorer) == 3)
    #expect(gameTotal(seattle, scorer) == 9)
    #expect(statTotal(FantasyStat.defensiveSacks, newEngland, scorer) == 2)
    #expect(gameTotal(newEngland, scorer) == 2)
}

// MARK: - The scoring table

/// ESPN's `settings.scoringSettings.scoringItems`, carried by the `mSettings` view the
/// league request already asks for. Extra fields are ignored, and one bad line costs
/// only that line.
@Test func decodesALeaguesScoringTable() throws {
    let json = """
    {"settings": {"name": "Sunday Scaries", "scoringSettings": {"scoringItems": [
        {"statId": 3, "points": 0.04, "isReverseItem": false, "leagueRanking": 0.0, "leagueTotal": 0.0, "pointsOverrides": {}},
        {"statId": 53, "points": 1, "pointsOverrides": {"6": 1.5}},
        {"statId": 101, "points": 6.0, "pointsOverrides": {"16": 4.0}},
        {"statId": "bad", "points": 2.0},
        {"statId": 20, "points": -2.0, "pointsOverrides": "not a map"}
    ]}}}
    """
    let dto = try JSONDecoder().decode(FantasyLeagueDTO.self, from: Data(json.utf8))
    #expect(dto.settings?.name == "Sunday Scaries")
    let rules = FantasyMapper.scoringRules(from: dto.settings?.scoringSettings?.value)

    let table = rules.points
    #expect(table == [3: 0.04, 53: 1, 101: 6, 20: -2])
    // A tight end premium, keyed by the tight end's lineup slot.
    #expect(rules.value(of: 53, for: .tightEnd) == 1.5)
    #expect(rules.value(of: 53, for: .wideReceiver) == 1)
    // A return touchdown worth less to a team defense than to a returner.
    #expect(rules.value(of: 101, for: .defense) == 4)
    #expect(rules.value(of: 101, for: .runningBack) == 6)
    #expect(rules.value(of: 99, for: .defense) == 0)
}

/// A scoring block in a shape never seen must not cost the matchup.
@Test func aMalformedScoringTableLeavesTheLeagueReadable() throws {
    let json = #"{"settings": {"name": "League", "scoringSettings": {"scoringItems": 7}}}"#
    let dto = try JSONDecoder().decode(FantasyLeagueDTO.self, from: Data(json.utf8))
    #expect(dto.settings?.name == "League")
    let rules = FantasyMapper.scoringRules(from: dto.settings?.scoringSettings?.value)
    #expect(rules.isEmpty)
}

@Test func theMatchupCarriesItsLeaguesScoring() throws {
    let json = """
    {"scoringPeriodId": 1, "settings": {"name": "L", "scoringSettings": {"scoringItems": [{"statId": 43, "points": 6}]}},
     "members": [{"id": "{ME}"}],
     "teams": [{"id": 1, "owners": ["{ME}"], "roster": {"entries": [
        {"lineupSlotId": 4, "playerPoolEntry": {"player": {"id": 4430878, "fullName": "Jaxon Smith-Njigba", "firstName": "Jaxon", "lastName": "Smith-Njigba", "defaultPositionId": 3, "proTeamId": 26}}}
     ]}}]}
    """
    let dto = try JSONDecoder().decode(FantasyLeagueDTO.self, from: Data(json.utf8))
    let matchup = try #require(FantasyMapper.matchup(from: dto, swid: "{ME}"))
    let table = matchup.scoringRules.points
    #expect(table == [43: 6])
}

// MARK: - One play at a time

private func onlyLine(_ player: RosterPlayer, _ plays: [Play], game: Game? = neAtSea) -> [FantasyPlayLine] {
    FantasyGameScorer(detail: scoringFeed(plays), game: game).lines(for: player)
}

private func points(_ player: RosterPlayer, _ plays: [Play], rules: FantasyScoringRules = recordedRules) -> [Double] {
    onlyLine(player, plays).map { rules.points(for: $0.stats, position: player.position) }
}

private let darnold = scoringPlayer(3912547, "Sam", "Darnold", .quarterback)
private let myers = scoringPlayer(2473037, "Jason", "Myers", .kicker)
private let seahawks = scoringPlayer(-16026, "Seahawks", "D/ST", .defense, team: 26)
private let patriots = scoringPlayer(-16017, "Patriots", "D/ST", .defense, team: 17)

/// A touchdown pass is worth something different to each player it names: the yards and
/// the four to the passer, the catch, the yards and the six to the receiver, and the
/// extra point written onto the end of it to the kicker.
@Test func aTouchdownPassScoresForEveryoneInIt() {
    let play = scoringSnap("td", "S.Darnold pass short left to J.Smith-Njigba for 15 yards, TOUCHDOWN. J.Myers extra point is GOOD, Center-C.Stoll, Holder-M.Dickson.", score: .touchdown)
    #expect(points(darnold, [play]) == [4.6])
    #expect(points(smithNjigba, [play]) == [8.5])
    #expect(points(myers, [play]) == [1])

    let receiver = onlyLine(smithNjigba, [play])[0].stats
    #expect(receiver.isTouchdown)
    #expect(receiver[FantasyStat.targets] == 1)
    #expect(!onlyLine(myers, [play])[0].stats.isTouchdown)
}

@Test func incompletionsSacksAndPicksScoreWhatTheyCost() {
    let incomplete = scoringSnap("i", "(Shotgun) S.Darnold pass incomplete short right to J.Smith-Njigba.")
    let sack = scoringSnap("s", "(Shotgun) S.Darnold sacked at SEA 49 for -5 yards (D.Jones).")
    let pick = scoringSnap("x", "S.Darnold pass deep left intended for J.Smith-Njigba INTERCEPTED by C.Gonzalez at NE 10. C.Gonzalez to NE 30 for 20 yards (J.Smith-Njigba).")
    #expect(points(darnold, [incomplete, sack, pick]) == [0, 0, -2])
    // Targeted twice, caught nothing, and named as the tackler on the return.
    #expect(points(smithNjigba, [incomplete, sack, pick]) == [0, 0, 0])
    let targets = onlyLine(smithNjigba, [incomplete, sack, pick]).map { $0.stats[FantasyStat.targets] }
    #expect(targets == [1, 0, 1])
    let attempts = onlyLine(darnold, [incomplete, sack, pick]).map { $0.stats[FantasyStat.passAttempts] }
    #expect(attempts == [1, 0, 1])
}

/// A flag that wipes the play out wipes its points out; one enforced after the play
/// leaves the play's own yards alone.
@Test func nullifiedPlaysScoreNothingAndLateFlagsDoNotCount() {
    let wiped = scoringSnap("w", "(Shotgun) S.Darnold pass short left to J.Smith-Njigba for 7 yards, TOUCHDOWN NULLIFIED by Penalty.PENALTY on SEA, Illegal Shift, 5 yards, enforced at NE 7 - No Play.")
    let roughness = scoringSnap("r", "(Shotgun) S.Darnold scrambles right end pushed ob at NE 27 for 1 yard (B.Murphy).PENALTY on NE-D.Hall, Unnecessary Roughness, 15 yards, enforced at NE 27.")
    #expect(points(smithNjigba, [wiped]) == [0])
    #expect(points(darnold, [wiped, roughness]) == [0, 0.1])
}

/// The placeholder scores nothing and says so, so an alert can wait for the ruling.
@Test func aPlayUnderReviewWaitsForItsRuling() {
    let lines = onlyLine(smithNjigba, [scoringSnap("u", "*** play under review ***")])
    #expect(lines[0].isUnderReview)
    #expect(lines[0].stats.isEmpty)
}

/// A pass with a lateral: the passer has the completion and the whole play's yards,
/// the catcher his catch and his own leg, the man pitched to his leg and no catch.
@Test func lateralsAreSplitLegByLeg() {
    let walker = scoringPlayer(4567048, "Kenneth", "Walker III", .runningBack)
    let play = scoringSnap("l", "S.Darnold pass short right to J.Smith-Njigba to SEA 40 for 10 yards. J.Smith-Njigba lateral to K.Walker to NE 40 for 20 yards (C.Gonzalez).")
    #expect(points(darnold, [play]) == [1.2])
    #expect(points(smithNjigba, [play]) == [2])
    #expect(points(walker, [play]) == [2])
    let line = onlyLine(darnold, [play])[0].stats
    #expect(line[FantasyStat.passCompletions] == 1)
    #expect(line[FantasyStat.passingYards] == 30)
    #expect(onlyLine(walker, [play])[0].stats[FantasyStat.receptions] == 0)
}

/// CHI @ ATL, against ESPN's box score: Williams 14 passing yards for the play, Odunze
/// a catch for 2, Roschon Johnson 12 receiving yards and no catch.
@Test func aLateralPlayMatchesESPNsBoxScore() {
    let williams = scoringPlayer(4431611, "Caleb", "Williams", .quarterback, team: 3)
    let odunze = scoringPlayer(4431299, "Rome", "Odunze", team: 3)
    let johnson = scoringPlayer(4426386, "Roschon", "Johnson", .runningBack, team: 3)
    var play = scoringSnap("cw", "(Shotgun) C.Williams pass short right to R.Odunze to ATL 40 for 2 yards. Lateral to R.Johnson pushed ob at ATL 28 for 12 yards (H.Perkins).", offense: "3")
    play.yards = 14
    #expect(points(williams, [play]) == [0.56])
    #expect(points(odunze, [play]) == [1.2])
    #expect(points(johnson, [play]) == [1.2])
}

@Test func aFumbleLostCostsTheCarrier() {
    let walker = scoringPlayer(4567048, "Kenneth", "Walker III", .runningBack)
    let lost = scoringSnap("f", "K.Walker left end to SEA 30 for 5 yards (C.Gonzalez). FUMBLES (C.Gonzalez), RECOVERED by NE-K.Byard at SEA 30.")
    let kept = scoringSnap("k", "K.Walker up the middle to SEA 35 for 2 yards (K.Byard). FUMBLES (K.Byard), recovered by SEA-C.Kupp at SEA 35.")
    #expect(points(walker, [lost, kept]) == [-1.5, 0.2])
    let fumbles = onlyLine(walker, [lost, kept]).map { $0.stats[FantasyStat.fumbles] }
    #expect(fumbles == [1, 1])
    // The defense that fell on it.
    #expect(points(patriots, [lost, kept]) == [2, 0])
}

/// Chase Brown, CIN @ MIA: caught for 3, fumbled, and Miami's returner fumbled too
/// before Miami fell on it. Two loose balls once named nobody, so Brown kept the 2
/// points ESPN took off him. The second fumble is Miami's, not his.
@Test func aFumbleLostStillCostsTheCarrierWhenTheReturnerFumblesToo() {
    let brown = scoringPlayer(4362238, "Chase", "Brown", .runningBack, team: 4)
    let cinAtMia = Game(
        id: "401872982", shortName: "CIN @ MIA", phase: .live, statusDetail: "",
        period: 3, displayClock: "5:00",
        home: TeamSide(id: "15", abbreviation: "MIA", displayName: "Miami Dolphins",
                       shortName: "Dolphins", score: 0),
        away: TeamSide(id: "4", abbreviation: "CIN", displayName: "Cincinnati Bengals",
                       shortName: "Bengals", score: 0)
    )
    let play = scoringSnap("ff", "(Shotgun) J.Burrow pass short left to C.Brown to MIA 7 for 3 yards (C.Johnson). FUMBLES (C.Johnson), RECOVERED by MIA-C.Robinson at MIA 7. C.Robinson to MIA 18 for 11 yards (J.Chase). FUMBLES (J.Chase), recovered by MIA-J.Uche at MIA 23.", offense: "4")
    let line = onlyLine(brown, [play], game: cinAtMia)[0].stats
    #expect(line[FantasyStat.fumbles] == 1)
    #expect(line[FantasyStat.fumblesLost] == 1)
    #expect(recordedRules.points(for: line, position: .runningBack) == -0.7)
}

// MARK: - Yards the box score counts short

private func matchup(away: (id: String, abbreviation: String), home: (id: String, abbreviation: String)) -> Game {
    Game(id: "g", shortName: "\(away.abbreviation) @ \(home.abbreviation)", phase: .final,
         statusDetail: "Final", period: 4, displayClock: "0:00",
         home: TeamSide(id: home.id, abbreviation: home.abbreviation, displayName: home.abbreviation,
                        shortName: home.abbreviation, score: 0),
         away: TeamSide(id: away.id, abbreviation: away.abbreviation, displayName: away.abbreviation,
                        shortName: away.abbreviation, score: 0))
}

private func statTotal(_ stat: Int, _ player: RosterPlayer, _ plays: [Play], game: Game) -> Double {
    onlyLine(player, plays, game: game).reduce(0) { $0 + $1.stats[stat] }
}

/// Recorded live on 11 October, each figure ESPN's box score for the play: a fumble's
/// yards run to where the loose ball was first touched or fallen on — whichever way it
/// went if his side kept it, never past where he lost it if the other side did.
@Test func aFumblesYardsStopWhereTheLooseBallDid() {
    // NYG @ WSH: no gain to the WAS 24, Washington fell on it at the WAS 23. Box: 0.
    let nygAtWsh = matchup(away: ("19", "NYG"), home: ("28", "WSH"))
    let skattebo = scoringPlayer(4696981, "Cam", "Skattebo", .runningBack, team: 19)
    let lostForward = scoringSnap("k", "(Shotgun) C.Skattebo up the middle to WAS 24 for no gain (D.Payne; S.Styles). FUMBLES (D.Payne), RECOVERED by WAS-S.Tuttle at WAS 23.", offense: "19")
    #expect(statTotal(FantasyStat.rushingYards, skattebo, [lostForward], game: nygAtWsh) == 0)

    // DEN @ LAC: to the LAC 36 for 19, touched 2 yards on, Denver's. Box: 19.
    let denAtLac = matchup(away: ("7", "DEN"), home: ("24", "LAC"))
    let kolar = scoringPlayer(4430807, "Charlie", "Kolar", .tightEnd, team: 24)
    let touchedForward = scoringSnap("l", "(Shotgun) J.Herbert pass short middle to C.Kolar to LAC 36 for 19 yards (T.Hufanga). FUMBLES (T.Hufanga), touched at LAC 38, RECOVERED by DEN-B.Jones at LAC 40.", offense: "24")
    #expect(statTotal(FantasyStat.receivingYards, kolar, [touchedForward], game: denAtLac) == 19)

    // CLE @ NYJ: to the CLV 5 for 6, fallen on by Cleveland at the CLV 7. Box: 4.
    let cleAtNyj = matchup(away: ("5", "CLE"), home: ("20", "NYJ"))
    let sadiq = scoringPlayer(4686363, "Kenyon", "Sadiq", .tightEnd, team: 20)
    let smith = scoringPlayer(15864, "Geno", "Smith", .quarterback, team: 20)
    let catchAndFumble = scoringSnap("s", "(Shotgun) G.Smith pass short right to K.Sadiq to CLV 5 for 6 yards (Q.Williams). FUMBLES (Q.Williams), RECOVERED by CLV-R.Hickman at CLV 7.", offense: "20")
    #expect(statTotal(FantasyStat.receivingYards, sadiq, [catchAndFumble], game: cleAtNyj) == 4)
    #expect(statTotal(FantasyStat.passingYards, smith, [catchAndFumble], game: cleAtNyj) == 4)

    // CLE @ NYJ: a run for -6, fallen on by a teammate back at the line. Box: 0.
    let allen = scoringPlayer(4685720, "Braelon", "Allen", .runningBack, team: 20)
    let forward = scoringSnap("a", "B.Allen right end to NYJ 40 for -6 yards (Q.Williams). FUMBLES (Q.Williams), recovered by NYJ-T.Patrick at NYJ 46.", offense: "20")
    #expect(statTotal(FantasyStat.rushingYards, allen, [forward], game: cleAtNyj) == 0)

    // DET @ ARI: to the ARZ 33 for 6, touched at the ARZ 40, kept at the ARZ 46. Box: -1.
    let detAtAri = matchup(away: ("8", "DET"), home: ("22", "ARI"))
    let stBrown = scoringPlayer(4374302, "Amon-Ra", "St. Brown", team: 8)
    let touched = scoringSnap("t", "(Shotgun) J.Goff pass short middle to A.St. Brown to ARZ 33 for 6 yards (B.Browning). FUMBLES (B.Browning), touched at ARZ 40, recovered by DET-T.Ratledge at ARZ 46.", offense: "8")
    #expect(statTotal(FantasyStat.receivingYards, stBrown, [touched], game: detAtAri) == -1)

    // MIN @ NO: a run with no direction for -8, fallen on 3 yards further back. Box: -11.
    let minAtNo = matchup(away: ("16", "MIN"), home: ("18", "NO"))
    let jefferson = scoringPlayer(4262921, "Justin", "Jefferson", team: 16)
    let reverse = scoringSnap("j", "(Shotgun) J.Jefferson to NO 49 for -8 yards (C.Wooden). FUMBLES (C.Wooden), recovered by MIN-K.Murray at MIN 48.", offense: "16")
    #expect(statTotal(FantasyStat.rushAttempts, jefferson, [reverse], game: minAtNo) == 1)
    #expect(statTotal(FantasyStat.rushingYards, jefferson, [reverse], game: minAtNo) == -11)

    // CIN @ MIA: forward out of bounds untouched is no extra gain. Box: 4.
    let cinAtMia = matchup(away: ("4", "CIN"), home: ("15", "MIA"))
    let all = scoringPlayer(4430886, "Erick", "All", .tightEnd, team: 4)
    let outOfBounds = scoringSnap("o", "(Shotgun) J.Burrow pass short right to E.All to MIA 24 for 4 yards (M.Taaffe). FUMBLES (M.Taaffe), ball out of bounds at MIA 18.", offense: "4")
    #expect(statTotal(FantasyStat.receivingYards, all, [outOfBounds], game: cinAtMia) == 4)

    // NYG @ HOU, 25 October: to the HST 27 for 2, fallen on by a teammate at the HST 31
    // and run on to the HST 34. Box: 2 for both.
    let nygAtHou = matchup(away: ("19", "NYG"), home: ("34", "HST"))
    let stroud = scoringPlayer(4432577, "C.J.", "Stroud", .quarterback, team: 34)
    let hutchinson = scoringPlayer(4429025, "Xavier", "Hutchinson", team: 34)
    let ranOn = scoringSnap("h", "(Shotgun) C.Stroud pass short middle to X.Hutchinson to HST 27 for 2 yards. FUMBLES, recovered by HST-W.Marks at HST 31. W.Marks to HST 34 for 3 yards (M.McFadden).", offense: "34")
    #expect(statTotal(FantasyStat.passingYards, stroud, [ranOn], game: nygAtHou) == 2)
    #expect(statTotal(FantasyStat.receivingYards, hutchinson, [ranOn], game: nygAtHou) == 2)
}

/// Recorded live, MIN @ NO: caught for 7, fumbled at once, run back 87 for a touchdown.
/// The 87 was being paid to the quarterback and the receiver as their own yards.
@Test func aFumbleReturnTouchdownIsNotTheReceiversYards() {
    let minAtNo = matchup(away: ("16", "MIN"), home: ("18", "NO"))
    let price = scoringPlayer(4683062, "Myles", "Price", team: 16)
    let murray = scoringPlayer(3917315, "Kyler", "Murray", .quarterback, team: 16)
    let play = scoringSnap("p", "(Shotgun) K.Murray pass short left to M.Price to NO 12 for 7 yards (M.Emerson; P.Werner). FUMBLES (M.Emerson), RECOVERED by NO-J.Sanker at NO 13. J.Sanker for 87 yards, TOUCHDOWN. D.Carlson extra point is No Good, Wide Left, Center-C.Adomitis, Holder-R.Wright.", offense: "16", score: .touchdown)
    #expect(statTotal(FantasyStat.receivingYards, price, [play], game: minAtNo) == 6)
    #expect(statTotal(FantasyStat.passingYards, murray, [play], game: minAtNo) == 6)
    #expect(statTotal(FantasyStat.fumblesLost, price, [play], game: minAtNo) == 1)
}

/// Recorded live: a flag on the offense enforced at its spot stops the gain there.
@Test func anOffensiveFlagAtItsSpotStopsTheGain() {
    // HOU @ TEN: to the HST 8 for 35, holding enforced at the HST 41. Box: 2.
    let houAtTen = matchup(away: ("34", "HOU"), home: ("10", "TEN"))
    let spears = scoringPlayer(4428557, "Tyjae", "Spears", .runningBack, team: 10)
    let holding = scoringSnap("h", "(Shotgun) C.Ward pass short left to T.Spears pushed ob at HST 8 for 35 yards (R.Blankenship). HST-J.Pitre was injured during the play. PENALTY on TEN-A.Schlottmann, Offensive Holding, 10 yards, enforced at HST 41.", offense: "10")
    #expect(statTotal(FantasyStat.receivingYards, spears, [holding], game: houAtTen) == 2)

    // HOU @ TEN: a 24-yard touchdown run called back for holding at the TEN 18. Box: a
    // carry for 6, and no touchdown.
    let marks = scoringPlayer(4890973, "Woody", "Marks", .runningBack, team: 34)
    let calledBack = scoringSnap("c", "(Shotgun) W.Marks right tackle for 24 yards, TOUCHDOWN NULLIFIED by Penalty.PENALTY on HST-B.Jordan, Offensive Holding, 10 yards, enforced at TEN 18.", offense: "34")
    #expect(statTotal(FantasyStat.rushingYards, marks, [calledBack], game: houAtTen) == 6)
    #expect(statTotal(FantasyStat.rushingTouchdowns, marks, [calledBack], game: houAtTen) == 0)

    // A flag on the defense leaves the gain alone.
    let roughness = scoringSnap("r", "(Shotgun) C.Ward pass short left to T.Spears pushed ob at HST 8 for 35 yards (R.Blankenship). PENALTY on HST-R.Blankenship, Unnecessary Roughness, 15 yards, enforced at HST 8.", offense: "10")
    #expect(statTotal(FantasyStat.receivingYards, spears, [roughness], game: houAtTen) == 35)
}

/// Recorded live, PHI vs JAX: one scramble posted twice once replay re-spotted it — two
/// play ids at 7:46 of the first quarter, both 3rd and 3 from the JAX 39, the next snap
/// 4th and 1 from the 37. ESPN's box score has one carry for 2.
@Test func aPlayPostedTwiceCountsOnce() {
    let phiJax = matchup(away: ("30", "JAX"), home: ("21", "PHI"))
    let hurts = scoringPlayer(4040715, "Jalen", "Hurts", .quarterback, team: 21)
    func snap(_ id: String, _ text: String, down: Int, distance: Int, toGo: Int, clock: String) -> Play {
        Play(id: id, sequence: 0, typeID: "5", typeText: "Rush", text: text,
             downDistanceText: nil, yards: 0, period: 1, clock: clock,
             isScoring: false, scoreKind: nil, isTurnover: false, isPenalty: false,
             start: PlayNode(teamID: "21", yardsToEndzone: toGo, down: down, distance: distance),
             end: PlayNode(), kind: .scrimmage)
    }
    let plays = [
        snap("1", "(No Huddle, Shotgun) J.Hurts scrambles right end ran ob at JAX 37 for 2 yards (V.Miller).  The ball spot was assisted by replay.", down: 3, distance: 3, toGo: 39, clock: "7:46"),
        snap("2", "(No Huddle, Shotgun) J.Hurts scrambles right tackle pushed ob at JAX 37 for 2 yards (F.Oluokun).  The ball spot was assisted by replay.", down: 3, distance: 3, toGo: 39, clock: "7:46"),
        snap("3", "(Shotgun) J.Hurts up the middle to JAX 36 for 1 yard (V.Miller).", down: 4, distance: 1, toGo: 37, clock: "6:56"),
    ]
    let lines = onlyLine(hurts, plays, game: phiJax)
    #expect(lines.map(\.play.id) == ["2", "3"])
    #expect(lines.reduce(0) { $0 + $1.stats[FantasyStat.rushingYards] } == 3)
}

// MARK: - Kicks

/// A field goal is scored by distance, a miss costs a point, and the kickoff that
/// follows earns the kicker nothing.
@Test func kickersScoreTheirKicksAndNotTheirKickoffs() {
    let short = scoringSnap("a", "J.Myers 30 yard field goal is GOOD, Center-C.Stoll, Holder-M.Dickson.", score: .fieldGoal)
    let long = scoringSnap("b", "J.Myers 48 yard field goal is GOOD, Center-C.Stoll, Holder-M.Dickson.", score: .fieldGoal)
    let longer = scoringSnap("c", "J.Myers 56 yard field goal is GOOD, Center-C.Stoll, Holder-M.Dickson.", score: .fieldGoal)
    let miss = scoringSnap("d", "J.Myers 52 yard field goal is No Good, Wide Right, Center-C.Stoll, Holder-M.Dickson.")
    let kickoff = scoringSnap("e", "J.Myers kicks 65 yards from SEA 35 to end zone, Touchback.")
    #expect(points(myers, [short, long, longer, miss, kickoff]) == [3, 4, 5, -1, 0])

    let missLine = onlyLine(myers, [miss])[0].stats
    #expect(missLine[FantasyStat.fieldGoalsMissed50To59] == 1)
    #expect(missLine[FantasyStat.fieldGoalsAttempted] == 1)
}

@Test func aMissedExtraPointCosts() {
    let play = scoringSnap("m", "K.Walker right end for 1 yard, TOUCHDOWN. J.Myers extra point is No Good, Wide Right, Center-C.Stoll, Holder-M.Dickson.", score: .touchdown)
    #expect(points(myers, [play]) == [-1])
}

/// ESPN posts the kick as a play of its own while the touchdown may already end with it.
/// It counts once: on the touchdown when the touchdown carries it, otherwise on its own.
@Test func anExtraPointIsNeverCountedTwice() {
    let withKick = scoringSnap("t1", "S.Darnold pass short left to J.Smith-Njigba for 15 yards, TOUCHDOWN. J.Myers extra point is GOOD, Center-C.Stoll, Holder-M.Dickson.", score: .touchdown)
    let kick = scoringSnap("k1", "J.Myers extra point is GOOD, Center-C.Stoll, Holder-M.Dickson.")
    #expect(points(myers, [withKick, kick]) == [1, 0])

    let bare = scoringSnap("t2", "S.Darnold pass short left to J.Smith-Njigba for 15 yards, TOUCHDOWN.", score: .touchdown)
    let summaryKick = scoringSnap("k2", "(Jason Myers Kick)")
    #expect(points(myers, [bare, summaryKick]) == [0, 1])
    #expect(points(myers, [bare, summaryKick, kick]) == [0, 1, 0])
}

@Test func twoPointConversionsScoreForThePasserAndCatcher() {
    let kupp = scoringPlayer(2977187, "Cooper", "Kupp")
    let appended = scoringSnap("a", "K.Walker right end for 27 yards, TOUCHDOWN. TWO-POINT CONVERSION ATTEMPT. S.Darnold pass to C.Kupp is complete. ATTEMPT SUCCEEDS.", score: .touchdown)
    #expect(points(darnold, [appended]) == [2])
    #expect(points(kupp, [appended]) == [2])

    let bare = scoringSnap("b", "K.Walker right end for 27 yards, TOUCHDOWN.", score: .touchdown)
    let standalone = scoringSnap("c", "TWO-POINT CONVERSION ATTEMPT. S.Darnold pass to C.Kupp is complete. ATTEMPT SUCCEEDS.")
    #expect(points(kupp, [bare, standalone]) == [0, 2])

    let summary = scoringSnap("d", "(Sam Darnold Pass to Cooper Kupp for Two-Point Conversion)")
    #expect(points(kupp, [bare, summary]) == [0, 2])
}

// MARK: - Team defense

/// A team defense is never named, so it scores on what its side did — never on its own
/// team's offense.
@Test func teamDefensesScoreTheirOwnStops() {
    let sack = scoringSnap("s", "(Shotgun) D.Maye sacked at NE 30 for -6 yards (D.Hall).", offense: "17")
    let pick = scoringSnap("i", "D.Maye pass deep left intended for R.Doubs INTERCEPTED by N.Pritchett at SEA 3. N.Pritchett to SEA 33 for 30 yards (J.Wilson).", offense: "17")
    let theirSack = scoringSnap("t", "(Shotgun) S.Darnold sacked at SEA 49 for -5 yards (D.Jones).", offense: "26")
    #expect(points(seahawks, [sack, pick, theirSack]) == [1, 2, 0])
    #expect(points(patriots, [sack, pick, theirSack]) == [0, 0, 1])
}

@Test func returnTouchdownsScoreForTheDefenseAndTheReturner() {
    let pickSix = scoringSnap("p", "(Shotgun) D.Maye pass short middle intended for H.Henry INTERCEPTED by D.Witherspoon at NE 30. D.Witherspoon for 30 yards, TOUCHDOWN. J.Myers extra point is GOOD, Center-C.Stoll, Holder-M.Dickson.", offense: "17", score: .touchdown)
    // Seattle's own kicker kicks after Seattle's defensive score.
    #expect(points(seahawks, [pickSix]) == [8])
    #expect(points(myers, [pickSix]) == [1])
    #expect(points(maye, [pickSix]) == [-2])

    let puntReturn = scoringSnap("r", "M.Wishnowsky punts 45 yards to SEA 20, Center-J.Ashby. R.Shaheed for 80 yards, TOUCHDOWN. J.Myers extra point is GOOD, Center-C.Stoll, Holder-M.Dickson.", offense: "17", score: .touchdown)
    #expect(points(seahawks, [puntReturn]) == [6])
    #expect(points(shaheed, [puntReturn]) == [6])
    #expect(onlyLine(shaheed, [puntReturn])[0].stats.isTouchdown)

    let stripSix = scoringSnap("f", "(No Huddle) D.Maye sacked at NE 25 for -8 yards (D.Hall). FUMBLES (D.Hall), RECOVERED by SEA-E.Jones at NE 27. E.Jones for 27 yards, TOUCHDOWN. J.Myers extra point is GOOD, Center-C.Stoll, Holder-M.Dickson.", offense: "17", score: .touchdown)
    // A sack, a recovery and the touchdown.
    #expect(points(seahawks, [stripSix]) == [9])
}

@Test func safetiesAndBlockedKicksScoreForTheDefense() {
    let safety = scoringSnap("s", "(Shotgun) D.Maye sacked in End Zone for -7 yards, SAFETY (D.Hall).", offense: "17", score: .safety)
    #expect(points(seahawks, [safety]) == [3])

    let blocked = scoringSnap("b", "A.Borregales 44 yard field goal is BLOCKED (L.Williams), Center-J.Ashby, Holder-M.Wishnowsky.", offense: "17")
    #expect(points(seahawks, [blocked]) == [2])
    #expect(points(scoringPlayer(4569923, "Andy", "Borregales", .kicker, team: 17), [blocked]) == [-1])
}

/// A muffed punt the kicking team falls on is a recovery for the kicking side's defense,
/// although that side started the play with the ball — and a fumble lost for the
/// returner, as ESPN's box score charges it.
@Test func aMuffedPuntIsARecoveryForTheKickingTeam() {
    let muff = scoringSnap("m", "M.Wishnowsky punts 48 yards to SEA 22, Center-J.Ashby. R.Shaheed MUFFS catch, RECOVERED by NE-M.Jones at SEA 28.", offense: "17")
    #expect(points(patriots, [muff]) == [2])
    #expect(points(seahawks, [muff]) == [0])
    #expect(points(shaheed, [muff]) == [-2])
    // Kept by his own side, it is nothing.
    let kept = scoringSnap("k", "M.Wishnowsky punts 48 yards to SEA 22, Center-J.Ashby. R.Shaheed MUFFS catch, and recovers at SEA 20.", offense: "17")
    #expect(points(shaheed, [kept]) == [0])
}

// MARK: - Names

/// A tackler or a player flagged for a penalty is named, not credited — even when he
/// shares a name with someone rostered on the other side.
@Test func tacklersAndFlaggedPlayersAreNeverCredited() {
    let jameson = scoringPlayer(4426388, "Jameson", "Williams", team: 8)
    let detroit = Game(id: "1", shortName: "CHI @ DET", phase: .live, statusDetail: "", period: 2,
                       displayClock: "5:00",
                       home: TeamSide(id: "8", abbreviation: "DET", displayName: "Lions", shortName: "Lions", score: 0),
                       away: TeamSide(id: "3", abbreviation: "CHI", displayName: "Bears", shortName: "Bears", score: 0))
    let plays = [
        scoringSnap("t", "J.Goff pass short right to A.St. Brown to DET 40 for 8 yards (J.Williams).", offense: "8"),
        scoringSnap("p", "J.Goff pass short right to A.St. Brown to DET 40 for 8 yards. PENALTY on CHI-J.Williams, Unnecessary Roughness, 15 yards, enforced at DET 40.", offense: "8"),
        // Chicago's own J.Williams carrying for Chicago.
        scoringSnap("o", "J.Williams up the middle to CHI 30 for 4 yards (A.Hutchinson).", offense: "3"),
        scoringSnap("c", "J.Goff pass deep left to J.Williams to CHI 20 for 40 yards (T.Smith).", offense: "8"),
    ]
    let lines = FantasyGameScorer(detail: scoringFeed(plays), game: detroit).lines(for: jameson)
    #expect(lines.map { recordedRules.points(for: $0.stats, position: .wideReceiver) } == [0, 0, 0, 5])
}

/// Rosters keep "III" and "Jr."; play text never does. And where one game's text uses
/// both "B.Robinson" and "Bi.Robinson", the longer form is Bijan's and the shorter is
/// somebody else.
@Test func suffixesAndLongerFormsAreReadRight() {
    let atlanta = Game(id: "2", shortName: "SF @ ATL", phase: .live, statusDetail: "", period: 2,
                       displayClock: "5:00",
                       home: TeamSide(id: "1", abbreviation: "ATL", displayName: "Falcons", shortName: "Falcons", score: 0),
                       away: TeamSide(id: "25", abbreviation: "SF", displayName: "49ers", shortName: "49ers", score: 0))
    let bijan = scoringPlayer(4430807, "Bijan", "Robinson", .runningBack, team: 1)
    let brian = scoringPlayer(4241474, "Brian", "Robinson Jr.", .runningBack, team: 25)
    let plays = [
        scoringSnap("1", "(Shotgun) M.Penix pass short right to Bi.Robinson for 23 yards, TOUCHDOWN.", offense: "1", score: .touchdown),
        scoringSnap("2", "B.Robinson left tackle to ATL 30 for 6 yards (K.Elliss).", offense: "25"),
    ]
    let scorer = FantasyGameScorer(detail: scoringFeed(plays), game: atlanta)
    #expect(scorer.lines(for: bijan).map { recordedRules.points(for: $0.stats, position: .runningBack) } == [9.3, 0])
    #expect(scorer.lines(for: brian).map { recordedRules.points(for: $0.stats, position: .runningBack) } == [0, 0.6])

    // Alone in a game, the short form is his.
    let alone = FantasyGameScorer(detail: scoringFeed([plays[1]]), game: atlanta)
    let cook = scoringPlayer(4379399, "James", "Cook III", .runningBack, team: 25)
    #expect(alone.lines(for: brian).map { recordedRules.points(for: $0.stats, position: .runningBack) } == [0.6])
    let cookRun = scoringSnap("3", "J.Cook up the middle to BUF 40 for 7 yards (Q.Williams).", offense: "25")
    #expect(onlyLine(cook, [cookRun], game: nil).map { recordedRules.points(for: $0.stats, position: .runningBack) } == [0.7])

    let amonRa = scoringPlayer(4374302, "Amon-Ra", "St. Brown", team: 8)
    let catchPlay = scoringSnap("4", "J.Goff pass short right to A.St. Brown to DET 40 for 8 yards (J.Johnson).", offense: "8")
    #expect(points(amonRa, [catchPlay]) == [1.8])
}

// MARK: - Game totals

/// Milestones and per-chunk yardage are game totals, so the play that crosses the line
/// takes the bonus — and taking a back past 200 swaps the 100-yard bonus for the 200.
@Test func milestonesLandOnThePlayThatCrossesThem() {
    let walker = scoringPlayer(4567048, "Kenneth", "Walker III", .runningBack)
    let rules = FantasyScoringRules(points: [
        FantasyStat.rushingYards: 0.1, 28: 1, 37: 3, 38: 5,
    ])
    let plays = [
        scoringSnap("a", "K.Walker left end to SEA 40 for 95 yards (C.Gonzalez)."),
        scoringSnap("b", "K.Walker up the middle to NE 30 for 8 yards (K.Byard)."),
        scoringSnap("c", "K.Walker right end to NE 10 for 100 yards (K.Byard)."),
    ]
    let lines = onlyLine(walker, plays)
    #expect(lines.map { $0.stats[28] } == [9, 1, 10])
    #expect(lines.map { $0.stats[37] } == [0, 1, -1])
    #expect(lines.map { $0.stats[38] } == [0, 0, 1])
    #expect(lines.map { rules.points(for: $0.stats, position: .runningBack) } == [18.5, 4.8, 22])
}
