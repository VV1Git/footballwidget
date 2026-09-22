import Foundation
import Testing
@testable import FootballCore

// This fixture is a reconstruction of ESPN's v3 league shape, not a recording — no
// league credentials were available to capture a real one. `--dump-fantasy` replaces
// it with a real payload once a league is connected, at which point these tests start
// running against reality. Until then they pin the mapping logic, not the wire format.
private func league() throws -> FantasyLeagueDTO {
    let located = Bundle.module.url(forResource: "league", withExtension: "json",
                                    subdirectory: "Fixtures")
    let url = try #require(located)
    return try JSONDecoder().decode(FantasyLeagueDTO.self, from: Data(contentsOf: url))
}

private let mySWID = "{AAAA-1111}"

// MARK: - Identifying your team

@Test func resolvesYourTeamFromTheSWID() throws {
    let matchup = try #require(FantasyMapper.matchup(from: try league(), swid: mySWID))
    #expect(matchup.mine.id == 1)
    #expect(matchup.mine.name == "My Team")
    #expect(matchup.opponent?.id == 2)
    #expect(matchup.leagueName == "Sunday Scaries")
    #expect(matchup.week == 1)
}

/// Browsers hand the SWID over with or without braces and in either case.
@Test func toleratesSWIDFormatting() throws {
    let dto = try league()
    for variant in ["{AAAA-1111}", "AAAA-1111", "  {aaaa-1111}  "] {
        let matchup = FantasyMapper.matchup(from: dto, swid: variant)
        #expect(matchup?.mine.id == 1, "failed for \(variant)")
    }
}

@Test func returnsNothingForAnUnknownSWID() throws {
    #expect(FantasyMapper.matchup(from: try league(), swid: "{ZZZZ-9999}") == nil)
    #expect(FantasyMapper.matchup(from: try league(), swid: "") == nil)
}

/// Older leagues split the team name into location and nickname.
@Test func buildsTeamNameFromLocationAndNickname() throws {
    let matchup = try #require(FantasyMapper.matchup(from: try league(), swid: mySWID))
    #expect(matchup.opponent?.name == "Their Team")
}

// MARK: - Rosters

@Test func splitsStartersFromBenchAndIR() throws {
    let matchup = try #require(FantasyMapper.matchup(from: try league(), swid: mySWID))
    let starters = matchup.mine.starters.map(\.fullName)
    #expect(starters == ["Josh Allen", "Ja'Marr Chase", "Jaxon Smith-Njigba"])

    let bench = matchup.mine.bench.map(\.fullName)
    #expect(bench == ["Drake Maye", "Sam Darnold"])
    #expect(matchup.mine.roster.first { $0.fullName == "Sam Darnold" }?.slot == .injuredReserve)
}

@Test func readsLivePointsAndPositions() throws {
    let matchup = try #require(FantasyMapper.matchup(from: try league(), swid: mySWID))
    let chase = try #require(matchup.mine.roster.first { $0.id == 4362628 })
    #expect(chase.points == 26.7)
    #expect(chase.position == .wideReceiver)
    #expect(chase.slot == .starting("WR"))
    #expect(chase.proTeamID == 4)

    let allen = try #require(matchup.mine.roster.first { $0.id == 3918298 })
    #expect(allen.position == .quarterback)
    #expect(allen.slot == .starting("QB"))
}

@Test func usesTeamTotalsFromTheMatchup() throws {
    let matchup = try #require(FantasyMapper.matchup(from: try league(), swid: mySWID))
    #expect(matchup.mine.points == 63.2)
    #expect(matchup.opponent?.points == 41.5)
    #expect(matchup.isLeading)
    #expect(matchup.compactScore == "63.2 – 41.5")
}

/// `statSourceId` 1 is a projection. Mistaking it for actual production would show
/// everyone having already scored their projected total.
@Test func neverMistakesProjectionsForPoints() throws {
    let json = Data("""
    [
      {"scoringPeriodId": 1, "statSourceId": 1, "appliedTotal": 99.9},
      {"scoringPeriodId": 1, "statSourceId": 0, "appliedTotal": 12.0}
    ]
    """.utf8)
    let stats = try JSONDecoder().decode([Failable<FantasyPlayerStatDTO>].self, from: json)
    #expect(FantasyMapper.actualPoints(from: stats) == 12.0)
}

/// The fixture gives every player both a projection and an actual; the roster must
/// show what they have really scored.
@Test func rosterPointsAreActualNotProjected() throws {
    let matchup = try #require(FantasyMapper.matchup(from: try league(), swid: mySWID))
    #expect(matchup.mine.roster.allSatisfy { $0.points < 99 })
}

// MARK: - Joining to NFL games

@Test func findsPlayersByNFLTeam() throws {
    let matchup = try #require(FantasyMapper.matchup(from: try league(), swid: mySWID))
    // 26 is Seattle in both ESPN's fantasy and NFL feeds.
    let seattle = matchup.players(onNFLTeam: 26)
    #expect(seattle.map(\.player.fullName).sorted() == ["Jaxon Smith-Njigba", "Sam Darnold"])
    #expect(seattle.allSatisfy { $0.isMine })
}

@Test func rendersNamesTheWayThePlayFeedWritesThem() throws {
    let matchup = try #require(FantasyMapper.matchup(from: try league(), swid: mySWID))
    let names = matchup.mine.roster.map(\.playFeedName)
    #expect(names.contains("J.Smith-Njigba"))
    #expect(names.contains("J.Chase"))
    #expect(names.contains("S.Darnold"))
}

/// Starters come back in lineup order so two teams can be shown side by side and
/// mostly pair up by position.
@Test func startersComeBackInLineupOrder() throws {
    let matchup = try #require(FantasyMapper.matchup(from: try league(), swid: mySWID))
    let slots = matchup.mine.starters.map(\.slot.label)
    #expect(slots == ["QB", "WR", "WR"])

    let opponentSlots = try #require(matchup.opponent).starters.map(\.slot.label)
    #expect(opponentSlots == ["QB", "RB", "WR"])
}

// MARK: - A week still being played

private func liveLeague() throws -> FantasyLeagueDTO {
    let located = Bundle.module.url(forResource: "league-live", withExtension: "json",
                                    subdirectory: "Fixtures")
    let url = try #require(located)
    return try JSONDecoder().decode(FantasyLeagueDTO.self, from: Data(contentsOf: url))
}

/// The reported bug: the widget showed 0–0 while the real matchup was 0–9.4.
///
/// `schedule[].totalPoints` is the settled score for the matchup period and ESPN leaves
/// it at zero until the week closes, so trusting it means the score never moves during
/// the games — which is the only time anyone is looking at it.
@Test func liveScoresComeFromTheRosterNotTheSettledTotal() throws {
    let matchup = try #require(FantasyMapper.matchup(from: try liveLeague(), swid: mySWID))
    #expect(matchup.mine.points == 9.4)
    #expect(matchup.opponent?.points == 0)
    #expect(matchup.compactScore == "9.4 – 0.0")
}

/// Bench players score nothing for you, however well they are doing.
@Test func benchPointsStayOutOfTheTotal() throws {
    let matchup = try #require(FantasyMapper.matchup(from: try liveLeague(), swid: mySWID))
    let bench = try #require(matchup.mine.roster.first { $0.fullName == "Drake Maye" })
    #expect(bench.points == 18.0)
    #expect(!bench.isStarter)
    // 9.4 from Chase alone — Maye's 18 on the bench must not be in there.
    #expect(matchup.mine.points == 9.4)
}

/// The stats array carries several weeks; the current scoring period is the one that
/// counts, and a projection must never be mistaken for it.
@Test func picksTheRightWeekOutOfTheStatsArray() throws {
    let json = Data("""
    [
      {"scoringPeriodId": 1, "statSourceId": 0, "appliedTotal": 44.4},
      {"scoringPeriodId": 2, "statSourceId": 1, "appliedTotal": 99.9},
      {"scoringPeriodId": 2, "statSourceId": 0, "appliedTotal": 12.0}
    ]
    """.utf8)
    let stats = try JSONDecoder().decode([Failable<FantasyPlayerStatDTO>].self, from: json)
    #expect(FantasyMapper.actualPoints(from: stats, scoringPeriod: 2) == 12.0)
    #expect(FantasyMapper.actualPoints(from: stats, scoringPeriod: 1) == 44.4)
}

/// With no roster to add up — a view that did not return one, or a lineup that has
/// genuinely scored nothing — the settled total is still used.
@Test func settledTotalIsUsedWhenThereIsNothingLiveToAddUp() throws {
    let json = Data("""
    {"teamId": 1, "totalPoints": 88.5}
    """.utf8)
    let side = try JSONDecoder().decode(FantasyMatchupSideDTO.self, from: json)
    let team = try #require(FantasyMapper.team(id: 1, teams: [], side: side, scoringPeriod: 1))
    #expect(team.roster.isEmpty)
    #expect(team.points == 88.5)
}

/// Summing doubles drifts; the score shown must be the clean two-decimal figure.
@Test func totalsDoNotDriftWhenSummed() throws {
    let matchup = try #require(FantasyMapper.matchup(from: try league(), swid: mySWID))
    #expect(matchup.mine.points == 63.2)   // 24.1 + 26.7 + 12.4, not 63.199999999999996
}

// MARK: - Against a real ESPN payload

/// Trimmed from an actual league response, member ids and team names redacted. This is
/// the shape that broke: the matchup's roster carries stub entries while the real one
/// hangs off `teams[]`, and the live score lives in `totalPointsLive` while
/// `totalPoints` sits at zero.
private func espnLeague() throws -> FantasyLeagueDTO {
    let located = Bundle.module.url(forResource: "league-espn", withExtension: "json",
                                    subdirectory: "Fixtures")
    let url = try #require(located)
    return try JSONDecoder().decode(FantasyLeagueDTO.self, from: Data(contentsOf: url))
}

private let realSWID = "{AAAA-0001-0000-0000-000000000001}"

/// The reported bug: the widget showed 0–0 while ESPN's own app showed 0–11.42.
@Test func readsLiveScoresFromARealPayload() throws {
    let matchup = try #require(FantasyMapper.matchup(from: try espnLeague(), swid: realSWID))
    // `totalPoints` is 0 across this whole payload; 13.02 only exists in
    // `totalPointsLive`, which is what was being ignored.
    #expect(matchup.opponent?.points == 13.02)
    #expect(matchup.compactScore.contains("13.0"))
}

/// The matchup-side roster entries have no player id at all. Requiring one dropped
/// every player and left the roster empty, which is why there was nothing to add up.
@Test func buildsTheRosterEvenThoughTheMatchupCopyIsStubs() throws {
    let matchup = try #require(FantasyMapper.matchup(from: try espnLeague(), swid: realSWID))
    #expect(matchup.mine.roster.count == 17)
    #expect(matchup.opponent?.roster.count == 16)

    // Real players, with the details the field map joins on.
    let named = matchup.mine.roster.filter { !$0.fullName.hasPrefix("Player ") }
    #expect(named.count == matchup.mine.roster.count)
    let withTeams = matchup.mine.roster.filter { $0.proTeamID != nil }
    #expect(withTeams.count == matchup.mine.roster.count)
}

@Test func separatesStartersFromTheBenchInARealLineup() throws {
    let matchup = try #require(FantasyMapper.matchup(from: try espnLeague(), swid: realSWID))
    #expect(!matchup.mine.starters.isEmpty)
    #expect(!matchup.mine.bench.isEmpty)
    #expect(matchup.mine.starters.count + matchup.mine.bench.count == matchup.mine.roster.count)
    // A real lineup has exactly one quarterback slot.
    #expect(matchup.mine.starters.filter { $0.slot.label == "QB" }.count == 1)
}

@Test func identifiesMyTeamFromTheRealSWID() throws {
    let matchup = try #require(FantasyMapper.matchup(from: try espnLeague(), swid: realSWID))
    #expect(matchup.mine.name == "My Team")
    #expect(matchup.opponent?.name == "Their Team")
}

// MARK: - Projections and win probability

/// A second real payload, recorded mid-Sunday with projections and ESPN's
/// `winProbability` left in. Members, team names and the league are redacted.
private func projectedLeague() throws -> FantasyLeagueDTO {
    let located = Bundle.module.url(forResource: "league-winprob", withExtension: "json",
                                    subdirectory: "Fixtures")
    let url = try #require(located)
    return try JSONDecoder().decode(FantasyLeagueDTO.self, from: Data(contentsOf: url))
}

@Test func readsESPNsWinProbabilityAndProjectedTotals() throws {
    let matchup = try #require(FantasyMapper.matchup(from: try projectedLeague(), swid: realSWID))
    #expect(matchup.espnWinProbability == 0.79)
    #expect(matchup.mine.projectedPoints == 131.48662858)
    #expect(matchup.opponent?.projectedPoints == 94.50208874)
    // "UNDECIDED" while the games are on.
    #expect(matchup.outcome == nil)
}

/// Real rosters carry this week's projection beside a whole-season one twenty times
/// larger, and last season's actual total too. Only the week's projection is wanted,
/// and none of it may leak into the points.
@Test func readsThisWeeksProjectionNotTheSeasons() throws {
    let matchup = try #require(FantasyMapper.matchup(from: try projectedLeague(), swid: realSWID))
    let daniels = try #require(matchup.mine.roster.first { $0.id == 4426348 })
    #expect(daniels.projectedPoints == 16.86076128)
    #expect(daniels.points == 0)

    #expect(matchup.mine.points == 59.3)
    #expect(matchup.opponent?.points == 36.22)
    // Every starter on both sides has a projection for the week.
    let starters = matchup.mine.starters + (matchup.opponent?.starters ?? [])
    #expect(starters.allSatisfy { $0.projectedPoints != nil })
}

/// The mapper reads projections now, which must not change what counts as scored.
@Test func projectionsNeverBecomePointsInTheReconstructedFixture() throws {
    let matchup = try #require(FantasyMapper.matchup(from: try league(), swid: mySWID))
    let chase = try #require(matchup.mine.roster.first { $0.id == 4362628 })
    #expect(chase.projectedPoints == 99.9)
    #expect(chase.points == 26.7)
    #expect(matchup.espnWinProbability == nil)
}

/// The stat lines of a player whose game has not started, as ESPN sends them: last
/// season's total, both season projections and this week's projection, but no actual
/// line for this week yet.
private let notYetPlayedStats = """
[
  {"seasonId": 2026, "scoringPeriodId": 1, "statSourceId": 1, "statSplitTypeId": 1, "appliedTotal": 16.86},
  {"seasonId": 2025, "scoringPeriodId": 0, "statSourceId": 0, "statSplitTypeId": 0, "appliedTotal": 114.28},
  {"seasonId": 2025, "scoringPeriodId": 0, "statSourceId": 1, "statSplitTypeId": 0, "appliedTotal": 372.11},
  {"seasonId": 2026, "scoringPeriodId": 0, "statSourceId": 1, "statSplitTypeId": 0, "appliedTotal": 328.13}
]
"""

/// Falling back to the first actual line in the array used to report last season's
/// 114.28 as this week's score.
@Test func aWeekWithNoActualLineScoresZeroNotLastSeason() throws {
    let stats = try JSONDecoder().decode([Failable<FantasyPlayerStatDTO>].self,
                                         from: Data(notYetPlayedStats.utf8))
    #expect(FantasyMapper.actualPoints(from: stats, scoringPeriod: 1) == 0)
    #expect(FantasyMapper.projectedPoints(from: stats, scoringPeriod: 1) == 16.86)
}

/// No known week, or a week with no projection, is no projection — not a guess.
@Test func projectionsNeedTheRightWeek() throws {
    let stats = try JSONDecoder().decode([Failable<FantasyPlayerStatDTO>].self,
                                         from: Data(notYetPlayedStats.utf8))
    #expect(FantasyMapper.projectedPoints(from: stats, scoringPeriod: nil) == nil)
    #expect(FantasyMapper.projectedPoints(from: stats, scoringPeriod: 2) == nil)
    #expect(FantasyMapper.projectedPoints(from: nil, scoringPeriod: 1) == nil)
}

@Test func readsTheSettledWinnerFromYourSide() throws {
    func outcome(_ winner: String?, iAmHome: Bool) throws -> MatchupOutcome? {
        let winnerField = winner.map { "\"winner\": \"\($0)\"," } ?? ""
        let json = Data("""
        {\(winnerField) "home": {"teamId": 1}, "away": {"teamId": 2}}
        """.utf8)
        let dto = try JSONDecoder().decode(FantasyMatchupDTO.self, from: json)
        return FantasyMapper.outcome(of: dto, myTeamID: iAmHome ? 1 : 2)
    }
    #expect(try outcome("HOME", iAmHome: true) == .won)
    #expect(try outcome("HOME", iAmHome: false) == .lost)
    #expect(try outcome("AWAY", iAmHome: false) == .won)
    #expect(try outcome("TIE", iAmHome: true) == .tied)
    #expect(try outcome("UNDECIDED", iAmHome: true) == nil)
    #expect(try outcome(nil, iAmHome: true) == nil)
}

// MARK: - Between two weeks

/// A third real payload, recorded on the Tuesday between week 1 and week 2: the new
/// week's opponent and lineups are set, and not one of its games has kicked off yet.
///
/// This is the shape that produced the bug below, and it is worth being precise about
/// what makes it nasty. ESPN answers with `scoringPeriodId: 2`, the week 2 matchup and
/// the week 2 lineup — but `teams[].roster` still carries every player's *week 1*
/// `appliedStatTotal`, because that field is not scoped to a week and only resets when
/// the new week's first game starts. Add those up over the week 2 starters and you get
/// a number that belongs to neither week.
private func betweenWeeksLeague() throws -> FantasyLeagueDTO {
    let located = Bundle.module.url(forResource: "league-betweenweeks", withExtension: "json",
                                    subdirectory: "Fixtures")
    let url = try #require(located)
    return try JSONDecoder().decode(FantasyLeagueDTO.self, from: Data(contentsOf: url))
}

/// The reported bug: "the league numbers show like the week 1 numbers vs my week 2
/// opponent". 130.46 is the week 2 starters scored with their week 1 points; the real
/// week 1 result was 110.06 and the real week 2 score is nothing yet.
@Test func lastWeeksPointsDoNotCarryIntoTheNewWeek() throws {
    let matchup = try #require(FantasyMapper.matchup(from: try betweenWeeksLeague(), swid: realSWID))
    #expect(matchup.week == 2)
    #expect(matchup.mine.points == 0)
    #expect(matchup.opponent?.points == 0)
    #expect(matchup.compactScore == "0.0 – 0.0")
}

/// The same staleness one level down: every player's `appliedStatTotal` is last week's
/// until his game starts, and none of it may reach the matchup view.
@Test func noPlayerCarriesLastWeeksPointsIntoTheNewWeek() throws {
    let matchup = try #require(FantasyMapper.matchup(from: try betweenWeeksLeague(), swid: realSWID))
    let everyone = matchup.mine.roster + (matchup.opponent?.roster ?? [])
    #expect(!everyone.isEmpty)
    #expect(everyone.allSatisfy { $0.points == 0 })
}

/// Zeroing the points must not zero the week. The opponent, the lineups and ESPN's
/// own projections are all real and all still have to come through.
@Test func theNewWeeksMatchupIsStillFullyBuilt() throws {
    let matchup = try #require(FantasyMapper.matchup(from: try betweenWeeksLeague(), swid: realSWID))
    #expect(matchup.mine.name == "My Team")
    #expect(matchup.opponent?.name == "Their Team")
    #expect(matchup.mine.roster.count == 17)
    #expect(matchup.opponent?.roster.count == 16)
    #expect(matchup.mine.starters.count == 9)

    // Names and NFL team ids are what the field map joins on.
    #expect(matchup.mine.roster.allSatisfy { !$0.fullName.hasPrefix("Player ") })
    #expect(matchup.mine.roster.allSatisfy { $0.proTeamID != nil })

    // ESPN's numbers for the week ahead, which are not stale.
    #expect(matchup.espnWinProbability == 0.43)
    #expect(matchup.mine.projectedPoints == 115.55368286)
    #expect(matchup.opponent?.projectedPoints == 129.78192455)
    #expect(matchup.mine.starters.allSatisfy { $0.projectedPoints != nil })
}

/// The week's projection sits in the same stats array as last week's actual total, so
/// the rule that keeps one out has to keep letting the other in.
@Test func thisWeeksProjectionSurvivesWhileLastWeeksPointsAreDropped() throws {
    let matchup = try #require(FantasyMapper.matchup(from: try betweenWeeksLeague(), swid: realSWID))
    let daniels = try #require(matchup.mine.roster.first { $0.fullName == "Jayden Daniels" })
    #expect(daniels.points == 0)                    // 17.66 of it was week 1's
    #expect(daniels.projectedPoints == 19.70636964)
}

/// From week two on, `appliedStatTotal` is not this week's points at all: it is the
/// season so far. Jaxon Smith-Njigba's week-two payload (recorded mid-game, 2026-09-20)
/// had 68.7 in it — his 26.2 from week one plus 42.5 from this week — while ESPN's own
/// screens showed 42.5. Only the per-week line is the week's score.
@Test func seasonToDateAppliedTotalIsNotThisWeeksScore() throws {
    let pool = try JSONDecoder().decode(
        FantasyPlayerPoolEntryDTO.self,
        from: Data(#"{"id": 4430878, "appliedStatTotal": 68.7, "player": {"id": 4430878}}"#.utf8))
    let stats = try JSONDecoder().decode([Failable<FantasyPlayerStatDTO>].self, from: Data("""
    [
      {"seasonId": 2026, "scoringPeriodId": 2, "statSourceId": 1, "statSplitTypeId": 1, "appliedTotal": 18.5},
      {"seasonId": 2026, "scoringPeriodId": 2, "statSourceId": 0, "statSplitTypeId": 1, "appliedTotal": 42.5},
      {"seasonId": 2026, "scoringPeriodId": 1, "statSourceId": 0, "statSplitTypeId": 1, "appliedTotal": 26.2},
      {"seasonId": 2025, "scoringPeriodId": 0, "statSourceId": 0, "statSplitTypeId": 0, "appliedTotal": 359.9},
      {"seasonId": 2026, "scoringPeriodId": 0, "statSourceId": 0, "statSplitTypeId": 0, "appliedTotal": 68.7}
    ]
    """.utf8))
    #expect(FantasyMapper.points(pool: pool, stats: stats, scoringPeriod: 2) == 42.5)
    // Week one is the one week where the two happen to agree.
    #expect(FantasyMapper.points(pool: pool, stats: stats, scoringPeriod: 1) == 26.2)
}

/// `appliedStatTotal` is still the answer where there is nothing better: the views that
/// send a roster with no stats attached at all.
@Test func fallsBackToAppliedTotalWhenThereAreNoStats() throws {
    let pool = try JSONDecoder().decode(
        FantasyPlayerPoolEntryDTO.self,
        from: Data(#"{"id": 1, "appliedStatTotal": 12.5, "player": {"id": 1}}"#.utf8))
    #expect(FantasyMapper.points(pool: pool, stats: nil, scoringPeriod: 2) == 12.5)
    #expect(FantasyMapper.points(pool: pool, stats: [], scoringPeriod: 2) == 12.5)
    // And where the period itself is unknown, since then nothing can be scoped to it.
    #expect(FantasyMapper.points(pool: pool, stats: nil, scoringPeriod: nil) == 12.5)
}
