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
