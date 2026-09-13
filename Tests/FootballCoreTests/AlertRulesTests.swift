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
    turnover: Bool = false,
    phase: GamePhase = .live
) -> Game {
    Game(
        id: "G1",
        shortName: "AWY @ HOM",
        phase: phase,
        statusDetail: "",
        period: 3,
        displayClock: "5:00",
        home: team("HOM", id: "H", score: home),
        away: team("AWY", id: "A", score: away),
        situation: Situation(
            possessionTeamID: possession,
            downDistanceText: "1st & 10 at HOM 15",
            isRedZone: redZone,
            lastPlayText: "A play happened",
            lastPlayID: lastPlayID,
            lastPlayWasTurnover: turnover
        )
    )
}

private func snapshot(
    home: Int = 0, away: Int = 0, redZone: Bool = false,
    possession: String? = "H", lastPlayID: String? = nil
) -> GameSnapshot {
    GameSnapshot(homeScore: home, awayScore: away, isRedZone: redZone,
                 possessionTeamID: possession, lastPlayID: lastPlayID)
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

@Test func scoringNamesThePointsAndTheTeam() throws {
    let cases: [(Int, String)] = [(7, "Touchdown"), (6, "Touchdown"), (3, "Field goal"), (2, "Safety")]
    for (points, label) in cases {
        let event = try #require(AlertRules.scoringEvent(
            previous: snapshot(home: 0),
            game: liveGame(home: points)
        ))
        #expect(event.title == "\(label) — HOM", "\(points) points")
        #expect(event.kind == .scoring)
    }
}

@Test func scoringCreditsWhicheverSideActuallyScored() throws {
    let event = try #require(AlertRules.scoringEvent(
        previous: snapshot(home: 10, away: 3),
        game: liveGame(home: 10, away: 10)
    ))
    #expect(event.title.hasSuffix("AWY"))
}

@Test func noScoringEventWhenTheScoreIsUnchanged() {
    #expect(AlertRules.scoringEvent(previous: snapshot(home: 7, away: 3),
                                    game: liveGame(home: 7, away: 3)) == nil)
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

// MARK: - Red zone

@Test func redZoneFiresOnEntryThenStaysQuiet() throws {
    let game = liveGame(possession: "H", redZone: true)
    let entering = try #require(AlertRules.redZoneEvent(previous: snapshot(redZone: false), game: game))
    #expect(entering.kind == .redZone)

    // Still in the red zone on the next snap: no second banner.
    #expect(AlertRules.redZoneEvent(previous: snapshot(redZone: true, possession: "H"), game: game) == nil)
}

/// A turnover inside the 20 flips who is threatening, which is worth knowing about.
@Test func redZoneReArmsWhenPossessionChanges() throws {
    let game = liveGame(possession: "A", redZone: true)
    let event = try #require(AlertRules.redZoneEvent(
        previous: snapshot(redZone: true, possession: "H"), game: game
    ))
    #expect(event.title.hasSuffix("AWY"))
}

@Test func noRedZoneEventOutsideTheTwenty() {
    #expect(AlertRules.redZoneEvent(previous: snapshot(redZone: false),
                                    game: liveGame(redZone: false)) == nil)
}

// MARK: - Identity

/// Event ids are the de-duplication key, so two different moments must not collide.
@Test func eventIDsAreDistinctPerMoment() throws {
    let first = try #require(AlertRules.scoringEvent(previous: snapshot(home: 0), game: liveGame(home: 7)))
    let second = try #require(AlertRules.scoringEvent(previous: snapshot(home: 7), game: liveGame(home: 14)))
    #expect(first.id != second.id)
}
