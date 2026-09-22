import Foundation
import Testing
@testable import FootballCore

// MARK: - Building matchups

/// A starter on NFL team `team`, so progress can be set per player.
private func starter(_ id: Int, team: Int, points: Double = 0,
                     projection: Double? = 15) -> RosterPlayer {
    RosterPlayer(id: id, fullName: "Player \(id)", firstName: "P", lastName: "\(id)",
                 position: .wideReceiver, slot: .starting("WR"), proTeamID: team,
                 points: points, injuryStatus: nil, projectedPoints: projection)
}

private func side(_ id: Int, points: Double, _ roster: [RosterPlayer],
                  projected: Double? = nil) -> FantasyTeam {
    FantasyTeam(id: id, name: "Team \(id)", abbreviation: "T\(id)", points: points,
                roster: roster, projectedPoints: projected)
}

private func matchup(mine: FantasyTeam, theirs: FantasyTeam?,
                     espn: Double? = nil, outcome: MatchupOutcome? = nil) -> FantasyMatchup {
    FantasyMatchup(leagueName: "Test League", week: 1, mine: mine, opponent: theirs,
                   espnWinProbability: espn, outcome: outcome)
}

/// Every NFL team in the same state.
private func everyone(_ progress: GameProgress?) -> (Int) -> GameProgress? {
    { _ in progress }
}

/// One starter each, on NFL teams 1 (mine) and 2 (theirs).
private func headToHead(mine: Double, theirs: Double,
                        myProjection: Double? = 15, theirProjection: Double? = 15,
                        espn: Double? = nil) -> FantasyMatchup {
    matchup(
        mine: side(1, points: mine, [starter(10, team: 1, points: mine, projection: myProjection)]),
        theirs: side(2, points: theirs, [starter(20, team: 2, points: theirs, projection: theirProjection)]),
        espn: espn
    )
}

// MARK: - The model

@Test func equalProjectionsBeforeKickoffAreATossUp() throws {
    let estimate = try #require(WinProbability.estimate(
        for: headToHead(mine: 0, theirs: 0), progress: everyone(.notStarted)
    ))
    #expect(estimate.source == .model)
    #expect(estimate.mine == 0.5)
    #expect(estimate.myPercentText == "50%")
    #expect(estimate.theirPercentText == "50%")
    #expect(estimate.projectedMine == 15)
    #expect(estimate.projectedTheirs == 15)
}

@Test func theBetterProjectedSideIsFavouredBeforeKickoff() throws {
    let estimate = try #require(WinProbability.estimate(
        for: headToHead(mine: 0, theirs: 0, myProjection: 25, theirProjection: 10),
        progress: everyone(.notStarted)
    ))
    #expect(estimate.mine > 0.5)
    #expect(estimate.mine < 0.99)
}

@Test func aBigLeadWithNothingLeftIsCertain() throws {
    let estimate = try #require(WinProbability.estimate(
        for: headToHead(mine: 120, theirs: 80), progress: everyone(.finished)
    ))
    #expect(estimate.source == .result)
    #expect(estimate.mine == 1)
    #expect(estimate.myPercentText == "100%")
    #expect(estimate.theirPercentText == "0%")
    // Nothing is projected once it is over.
    #expect(estimate.projectedMine == nil)
}

@Test func anExactTieWithEverythingFinishedIsFiftyFifty() throws {
    let estimate = try #require(WinProbability.estimate(
        for: headToHead(mine: 101.5, theirs: 101.5), progress: everyone(.finished)
    ))
    #expect(estimate.source == .result)
    #expect(estimate.mine == 0.5)
    #expect(estimate.myPercentText == "50%")
}

/// The same ten-point lead means more the less football is left to overturn it.
@Test func uncertaintyShrinksAsGamesFinish() throws {
    let lead = headToHead(mine: 60, theirs: 50)
    let stages: [GameProgress] = [.notStarted, .inProgress(remaining: 0.5),
                                  .inProgress(remaining: 0.1)]
    let forecasts = try stages.map {
        try #require(WinProbability.forecast(for: lead, progress: everyone($0)))
    }

    for (earlier, later) in zip(forecasts, forecasts.dropFirst()) {
        #expect(later.sigma < earlier.sigma)
        #expect(later.probability > earlier.probability)
        // Both sides are projected alike, so the expected margin stays the lead.
        #expect(abs(later.expectedMargin - 10) < 1e-9)
    }
    #expect(forecasts[0].probability > 0.5)

    let over = try #require(WinProbability.estimate(for: lead, progress: everyone(.finished)))
    #expect(over.mine == 1)
    #expect(over.isSettled)
}

/// σ is the square root of the remaining projected points times the fitted variance.
@Test func sigmaComesFromTheProjectedPointsStillToCome() throws {
    let forecast = try #require(WinProbability.forecast(
        for: headToHead(mine: 0, theirs: 0, myProjection: 20, theirProjection: 10),
        progress: everyone(.inProgress(remaining: 0.5))
    ))
    let expected = (WinProbability.variancePerProjectedPoint * (10 + 5)).squareRoot()
    #expect(abs(forecast.sigma - expected) < 1e-9)
    #expect(abs(forecast.expectedMine - 10) < 1e-9)
    #expect(abs(forecast.expectedTheirs - 5) < 1e-9)
}

@Test func normalCDFMatchesKnownValues() {
    #expect(WinProbability.normalCDF(0) == 0.5)
    #expect(abs(WinProbability.normalCDF(1) - 0.841345) < 1e-5)
    #expect(abs(WinProbability.normalCDF(-1.96) - 0.024998) < 1e-5)
}

// MARK: - When there is nothing honest to show

@Test func noOpponentMeansNoProbability() {
    let bye = matchup(mine: side(1, points: 80, [starter(10, team: 1)]), theirs: nil, espn: 0.7)
    #expect(WinProbability.estimate(for: bye, progress: everyone(.notStarted)) == nil)
}

/// A starter still to play without a projection would have to be guessed at.
@Test func aMissingProjectionHidesTheEstimate() {
    let unprojected = headToHead(mine: 40, theirs: 30, theirProjection: nil)
    #expect(WinProbability.estimate(for: unprojected, progress: everyone(.notStarted)) == nil)
    #expect(WinProbability.estimate(for: unprojected, progress: everyone(.inProgress(remaining: 0.2))) == nil)
}

/// Once his game is over a projection is irrelevant, so its absence costs nothing.
@Test func aMissingProjectionIsFineOnceThatGameIsOver() throws {
    let game = matchup(
        mine: side(1, points: 40, [starter(10, team: 1, projection: 15)]),
        theirs: side(2, points: 30, [starter(20, team: 2, projection: nil)])
    )
    let progress: (Int) -> GameProgress? = { $0 == 2 ? .finished : .notStarted }
    let estimate = try #require(WinProbability.estimate(for: game, progress: progress))
    #expect(estimate.source == .model)
    #expect(estimate.mine > 0.5)
}

/// A roster that did not load must not read as a certain win for the other side.
@Test func emptyLineupsProduceNothing() {
    let empty = matchup(mine: side(1, points: 30, []), theirs: side(2, points: 0, []))
    #expect(WinProbability.estimate(for: empty, progress: everyone(.finished)) == nil)
}

/// A player on a bye is projected for zero and has no game in the feed. He must not
/// keep the matchup open forever.
@Test func aByeDoesNotHoldTheResultOpen() throws {
    let game = matchup(
        mine: side(1, points: 90, [starter(10, team: 1), starter(11, team: 99, projection: 0)]),
        theirs: side(2, points: 70, [starter(20, team: 2)])
    )
    let progress: (Int) -> GameProgress? = { $0 == 99 ? nil : .finished }
    let estimate = try #require(WinProbability.estimate(for: game, progress: progress))
    #expect(estimate.source == .result)
    #expect(estimate.mine == 1)
}

/// A projected starter whose game cannot be found is assumed still to play, rather than
/// declared finished.
@Test func aMissingGameKeepsTheMatchupOpen() throws {
    let estimate = try #require(WinProbability.estimate(
        for: headToHead(mine: 90, theirs: 70), progress: everyone(nil)
    ))
    #expect(estimate.source == .model)
    #expect(!estimate.isSettled)
}

// MARK: - ESPN's number

@Test func espnsNumberIsPreferredWhenPresent() throws {
    // The model would call this nearly certain; ESPN's number is what its app shows.
    var game = headToHead(mine: 90, theirs: 20, espn: 0.79)
    game.mine.projectedPoints = 131.5
    game.opponent?.projectedPoints = 94.5
    let estimate = try #require(WinProbability.estimate(for: game, progress: everyone(.notStarted)))
    #expect(estimate.source == .espn)
    #expect(estimate.mine == 0.79)
    #expect(estimate.myPercentText == "79%")
    #expect(estimate.theirPercentText == "21%")
    #expect(estimate.projectedMine == 131.5)
    #expect(estimate.projectedTheirs == 94.5)
}

/// Without ESPN's projected totals, the model's expected finals stand in beside ESPN's
/// number rather than showing nothing.
@Test func espnsNumberFallsBackToModelProjections() throws {
    let estimate = try #require(WinProbability.estimate(
        for: headToHead(mine: 10, theirs: 5, espn: 0.6), progress: everyone(.notStarted)
    ))
    #expect(estimate.source == .espn)
    #expect(estimate.projectedMine == 25)
    #expect(estimate.projectedTheirs == 20)
}

/// ESPN rounds to two decimals, so a lopsided matchup comes back as exactly 1.0 while
/// there is still football to play. That must not read as a certainty.
@Test func certaintyIsClampedWhileGamesRemain() throws {
    let sure = try #require(WinProbability.estimate(
        for: headToHead(mine: 150, theirs: 40, espn: 1.0), progress: everyone(.inProgress(remaining: 0.1))
    ))
    #expect(sure.myPercentText == ">99%")
    #expect(sure.theirPercentText == "<1%")

    let hopeless = try #require(WinProbability.estimate(
        for: headToHead(mine: 40, theirs: 150, espn: 0.001), progress: everyone(.notStarted)
    ))
    #expect(hopeless.myPercentText == "<1%")
    #expect(hopeless.theirPercentText == ">99%")
}

/// Once every game is over the lead decides it, even if ESPN's number has not caught up.
@Test func finishedGamesOverrideAStaleESPNNumber() throws {
    let estimate = try #require(WinProbability.estimate(
        for: headToHead(mine: 100, theirs: 99, espn: 0.55), progress: everyone(.finished)
    ))
    #expect(estimate.source == .result)
    #expect(estimate.mine == 1)
}

@Test func aSettledOutcomeIsFinal() throws {
    let game = headToHead(mine: 0, theirs: 0, espn: 0.3)
    let cases: [(MatchupOutcome, Double, String)] = [(.won, 1, "100%"), (.lost, 0, "0%"), (.tied, 0.5, "50%")]
    for (outcome, expected, text) in cases {
        var settled = game
        settled.outcome = outcome
        let estimate = try #require(WinProbability.estimate(for: settled, progress: everyone(.notStarted)))
        #expect(estimate.source == .result)
        #expect(estimate.mine == expected)
        #expect(estimate.myPercentText == text)
    }
}

@Test func percentagesAlwaysAddUpToOneHundred() {
    for step in 0...1000 {
        let estimate = WinProbability(mine: Double(step) / 1000, source: .model)
        #expect(estimate.myPercent + estimate.theirPercent == 100)
    }
}

// MARK: - Game progress

private func game(_ phase: GamePhase, period: Int = 0, clock: String = "0:00") -> Game {
    let team = TeamSide(id: "1", abbreviation: "AAA", displayName: "A", shortName: "A", score: 0)
    let other = TeamSide(id: "2", abbreviation: "BBB", displayName: "B", shortName: "B", score: 0)
    return Game(id: "g", shortName: "A @ B", phase: phase, statusDetail: "",
                period: period, displayClock: clock, home: team, away: other)
}

@Test func readsGameProgressOffTheScoreboard() throws {
    #expect(GameProgress(game: game(.pre)) == .notStarted)
    #expect(GameProgress(game: game(.final, period: 4)) == .finished)
    #expect(GameProgress(game: game(.halftime, period: 2)) == .inProgress(remaining: 0.5))
    #expect(GameProgress(game: game(.unknown)) == nil)

    // Q1 with the full clock: all of it left.
    #expect(GameProgress(game: game(.live, period: 1, clock: "15:00"))?.remaining == 1)
    // Q3 7:30: a quarter and a half of four left.
    #expect(GameProgress(game: game(.live, period: 3, clock: "7:30"))?.remaining == 0.375)
    // Plain seconds are read as well.
    let late = try #require(GameProgress(game: game(.live, period: 4, clock: "45")))
    #expect(abs(late.remaining - 45.0 / 3600) < 1e-12)
    // Overtime is a sliver, never nothing, while the game is still on.
    let overtime = try #require(GameProgress(game: game(.live, period: 5, clock: "5:00")))
    #expect(overtime.remaining > 0 && overtime.remaining < 0.1)
}

// MARK: - Against a real ESPN payload

/// Trimmed from a live week-1 league response on 2026-09-13 with games in progress:
/// members, team names and the league redacted. ESPN's FantasyCast showed the same
/// matchup as 79%–21% with projected totals of 131.5 and 94.5.
private func winProbabilityLeague() throws -> FantasyLeagueDTO {
    let located = Bundle.module.url(forResource: "league-winprob", withExtension: "json",
                                    subdirectory: "Fixtures")
    let url = try #require(located)
    return try JSONDecoder().decode(FantasyLeagueDTO.self, from: Data(contentsOf: url))
}

private let winProbabilitySWID = "{AAAA-0001-0000-0000-000000000001}"

@Test func usesESPNsWinProbabilityFromARealPayload() throws {
    let game = try #require(FantasyMapper.matchup(from: try winProbabilityLeague(),
                                                  swid: winProbabilitySWID))
    let estimate = try #require(WinProbability.estimate(for: game, progress: everyone(nil)))
    #expect(estimate.source == .espn)
    #expect(estimate.myPercentText == "79%")
    #expect(estimate.theirPercentText == "21%")
    #expect(String(format: "%.1f", try #require(estimate.projectedMine)) == "131.5")
    #expect(String(format: "%.1f", try #require(estimate.projectedTheirs)) == "94.5")
}

/// With ESPN's number taken away, the same payload still yields an estimate, and it
/// leans the same way.
@Test func modelWorksFromARealPayloadWithoutESPNsNumber() throws {
    var game = try #require(FantasyMapper.matchup(from: try winProbabilityLeague(),
                                                  swid: winProbabilitySWID))
    game.espnWinProbability = nil
    let estimate = try #require(WinProbability.estimate(for: game, progress: everyone(.notStarted)))
    #expect(estimate.source == .model)
    #expect(estimate.mine > 0.5)
    #expect(estimate.mine < 1)
}
