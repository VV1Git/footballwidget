import Foundation
import Testing
@testable import FootballCore

// MARK: - Builders

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func side(_ abbr: String, id: String, score: Int) -> TeamSide {
    TeamSide(id: id, abbreviation: abbr, displayName: abbr, shortName: abbr, score: score)
}

private func ordinal(_ down: Int) -> String {
    ["1st", "2nd", "3rd", "4th"][down - 1]
}

/// KC (away, id 12) at BUF (home, id 2), KC's ball unless `ball` says otherwise. The
/// down-and-distance text is filled in the way ESPN writes it unless given.
private func game(
    id: String = "G1", kc: Int = 0, buf: Int = 0,
    period: Int = 1, clock: String = "10:00", phase: GamePhase = .live,
    ball: String? = "12", spot: String? = "KC 25",
    down: Int? = 1, distance: Int? = 10,
    short: String? = nil, downText: String? = nil,
    redZone: Bool = false, hasSituation: Bool = true
) -> Game {
    let shortText = short ?? down.flatMap { d in
        (1...4).contains(d) ? distance.map { "\(ordinal(d)) & \($0)" } : nil
    }
    let fullText = downText ?? shortText.map { text in spot.map { "\(text) at \($0)" } ?? text }
    return Game(
        id: id, shortName: "KC @ BUF", phase: phase, statusDetail: "",
        period: period, displayClock: clock,
        home: side("BUF", id: "2", score: buf),
        away: side("KC", id: "12", score: kc),
        situation: hasSituation ? Situation(
            possessionTeamID: ball, shortDownDistance: shortText, downDistanceText: fullText,
            possessionText: spot, down: down, distance: distance, isRedZone: redZone
        ) : nil
    )
}

private func ytg(_ game: Game) -> Int? {
    game.situation.flatMap { FieldPosition.yardsToGoal($0, in: game) }
}

private func rank(_ game: Game, _ leverage: FantasyLeverage = .none, recent: Moment? = nil) -> RankedGame {
    RedZoneRanker.rank(game, leverage: leverage, recent: recent, now: now)!
}

private func roster(_ id: Int, _ first: String, _ last: String, _ position: FantasyPosition,
                    team: Int) -> RosterPlayer {
    RosterPlayer(id: id, fullName: "\(first) \(last)", firstName: first, lastName: last,
                 position: position, slot: .starting(position.rawValue), proTeamID: team,
                 points: 0, injuryStatus: nil)
}

private func moment(_ title: String, kind: Moment.Kind = .scoring, age: TimeInterval) -> Moment {
    Moment(id: "G1|x", gameID: "G1", kind: kind, title: title, detail: nil, teamID: "12",
           clock: "Q1 10:00", at: now - age)
}

private func approx(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.001 }

// MARK: - Field position

/// The spot is written from the side of the field it is on, so the same "25" is a long
/// way out on your own side and nearly a score on theirs.
@Test func redZoneYardsToGoalReadsBothSidesOfTheField() {
    #expect(ytg(game(spot: "KC 25")) == 75)
    #expect(ytg(game(spot: "BUF 12")) == 12)
    #expect(ytg(game(spot: "50")) == 50)
    #expect(ytg(game(ball: "2", spot: "BUF 30")) == 70)
    #expect(ytg(game(ball: "2", spot: "KC 8")) == 8)
}

/// Spots can carry play-text abbreviations, which differ from the scoreboard's for a
/// handful of teams.
@Test func redZoneYardsToGoalAcceptsTextAbbreviations() {
    let ravens = Game(
        id: "G2", shortName: "HOU @ BAL", phase: .live, statusDetail: "", period: 1,
        displayClock: "10:00",
        home: side("BAL", id: "33", score: 0), away: side("HOU", id: "34", score: 0),
        situation: Situation(possessionTeamID: "33", possessionText: "BLT 30", down: 1, distance: 10)
    )
    #expect(ytg(ravens) == 70)
    var deep = ravens
    deep.situation?.possessionText = "HST 8"
    #expect(ytg(deep) == 8)
}

/// Kicks and tries come through with no possession or no down, and a spot nobody can
/// place is better left unplaced.
@Test func redZoneYardsToGoalIsNilWithoutADriveInProgress() {
    #expect(ytg(game(ball: nil, spot: "BUF 15")) == nil)
    #expect(ytg(game(down: nil)) == nil)
    #expect(ytg(game(down: 0)) == nil)
    #expect(ytg(game(down: 5)) == nil)
    #expect(ytg(game(spot: nil)) == nil)
    #expect(ytg(game(spot: "")) == nil)
    #expect(ytg(game(spot: "Midfield")) == nil)
    #expect(ytg(game(spot: "NYJ 20")) == nil)
    #expect(ytg(game(spot: "BUF 60")) == nil)
    #expect(ytg(game(spot: "40")) == nil)
}

@Test func redZoneFirstDownMarkerStopsAtTheGoalLine() {
    let fourthAndTwo = game(spot: "BUF 34", down: 4, distance: 2)
    #expect(FieldPosition.firstDownYardsToGoal(fourthAndTwo.situation!, in: fourthAndTwo) == 32)

    let goalToGo = game(spot: "BUF 3", down: 1, distance: 3, short: "1st & Goal")
    #expect(FieldPosition.firstDownYardsToGoal(goalToGo.situation!, in: goalToGo) == nil)

    let unknown = game(spot: "BUF 34", down: 2, distance: nil)
    #expect(FieldPosition.firstDownYardsToGoal(unknown.situation!, in: unknown) == nil)
}

// MARK: - Fantasy leverage

/// Only players on the team with the ball count as on offense; the user's defense
/// counts when it is the one on the field.
@Test func redZoneLeverageCountsTheOffenseAndMyDefense() {
    let players: [(player: RosterPlayer, isMine: Bool)] = [
        (roster(1, "Patrick", "Mahomes", .quarterback, team: 12), false),
        (roster(2, "Travis", "Kelce", .tightEnd, team: 12), true),
        (roster(3, "Josh", "Allen", .quarterback, team: 2), true),
        (roster(4, "Bills", "D/ST", .defense, team: 2), true),
    ]
    let leverage = FantasyLeverage(players: players, game: game())
    #expect(leverage == FantasyLeverage(mineOnOffense: 1, theirsOnOffense: 1, myDefenseOnField: true,
                                        leadName: "T. Kelce", leadIsMine: true))

    let billsBall = FantasyLeverage(players: players, game: game(ball: "2"))
    #expect(billsBall.mineOnOffense == 1)
    #expect(billsBall.theirsOnOffense == 0)
    #expect(!billsBall.myDefenseOnField)
    #expect(billsBall.leadName == "J. Allen")

    #expect(FantasyLeverage(players: players, game: game(ball: nil)) == .none)
}

/// Rosters keep the generational suffix; the reason line has no room for it.
@Test func redZoneLeverageLeadNameDropsTheSuffix() {
    let walker = roster(5, "Kenneth", "Walker III", .runningBack, team: 12)
    let leverage = FantasyLeverage(players: [(walker, false)], game: game())
    #expect(leverage.leadName == "K. Walker")
    #expect(!leverage.leadIsMine)
}

// MARK: - Ranking

@Test func redZoneRankIgnoresGamesThatAreNotLive() {
    #expect(RedZoneRanker.rank(game(phase: .pre), now: now) == nil)
    #expect(RedZoneRanker.rank(game(phase: .final), now: now) == nil)
}

/// Nobody wants to be shown a halftime show while a snap is happening somewhere else.
@Test func redZoneBreaksRankBelowAnySnap() {
    let half = rank(game(period: 2, clock: "0:00", phase: .halftime))
    #expect(half.reason == "Halftime")
    #expect(!half.inPlay)
    #expect(half.score < rank(game()).score)

    #expect(rank(game(period: 1, clock: "0:00")).reason == "End of Q1")
    #expect(rank(game(period: 3, clock: "0:00")).reason == "End of Q3")
    #expect(!rank(game(period: 3, clock: "0:00")).inPlay)
}

@Test func redZoneInsideTheTwentyOutranksMidfield() {
    let redZone = rank(game(spot: "BUF 15"))
    #expect(redZone.inRedZone)
    #expect(redZone.score > rank(game(spot: "50")).score)
    #expect(!rank(game(spot: "50")).inRedZone)
}

/// Same spot, so only goal-to-go and the down separate them.
@Test func redZoneThirdAndGoalOutranksFirstAndTen() {
    let third = rank(game(spot: "BUF 20", down: 3, distance: 20, short: "3rd & Goal"))
    let first = rank(game(spot: "BUF 20", down: 1, distance: 10))
    #expect(approx(third.score - first.score, 10))
}

/// ESPN says "red zone" while a try is lined up with nobody in possession; that is
/// the end of a drive, not one in progress.
@Test func redZoneNoFieldBonusOnATryWithoutPossession() {
    let tryForPoint = game(kc: 6, ball: nil, spot: "BUF 15", down: nil, distance: nil,
                           short: " & Goal", downText: " & Goal at BUF 15", redZone: true)
    let ranked = rank(tryForPoint)
    #expect(approx(ranked.score, 10))
    #expect(!ranked.inRedZone)
}

@Test func redZoneLateCloseGameOutranksAnEarlyRedZoneTrip() {
    let late = rank(game(kc: 17, buf: 14, period: 4, clock: "2:11", spot: "50"))
    let early = rank(game(period: 1, spot: "BUF 20"))
    #expect(late.score > early.score)
    #expect(late.reason == "One-score game, 2:11 left")
}

@Test func redZoneOvertimeRanksAboveMidFourthQuarter() {
    let overtime = rank(game(kc: 20, buf: 20, period: 5, clock: "8:00"))
    #expect(approx(overtime.score, 44))
    #expect(overtime.reason == "Overtime")
    #expect(overtime.score > rank(game(kc: 20, buf: 20, period: 4, clock: "8:00")).score)
}

/// A rout in the second half is damped; the same margin before halftime is not, since
/// a lot of football is left.
@Test func redZoneBlowoutsAreDampedInTheSecondHalf() {
    let close = rank(game(period: 3, spot: "BUF 15")).score
    #expect(approx(close, 39.5))
    #expect(approx(rank(game(kc: 28, period: 3, spot: "BUF 15")).score, close * 0.3))
    #expect(approx(rank(game(kc: 17, period: 3, spot: "BUF 15")).score, close * 0.5))
    #expect(approx(rank(game(kc: 28, period: 2, spot: "BUF 15")).score, close))
}

@Test func redZoneFantasyMineOutweighsTheirs() {
    let midfield = game(spot: "50")
    let none = rank(midfield).score
    let theirs = rank(midfield, FantasyLeverage(theirsOnOffense: 1)).score
    let mine = rank(midfield, FantasyLeverage(mineOnOffense: 1)).score
    #expect(mine > theirs && theirs > none)
    #expect(approx(mine - none, 6))
    #expect(approx(rank(midfield, FantasyLeverage(mineOnOffense: 4)).score - none, 15))
    #expect(approx(rank(midfield, FantasyLeverage(myDefenseOnField: true)).score - none, 3))
}

/// A starter about to touch the ball near the goal line is worth half as much again.
@Test func redZoneFantasyCountsMoreInsideTheTwenty() {
    let redZone = game(spot: "BUF 15")
    #expect(approx(rank(redZone, FantasyLeverage(mineOnOffense: 1)).score - rank(redZone).score, 9))
}

// MARK: - Reasons

@Test func redZoneReasonNamesTheBiggestFactor() {
    #expect(rank(game(period: 2, spot: "BUF 3", down: 3, distance: 3, short: "3rd & Goal")).reason
            == "Goal line · 3rd & Goal")
    #expect(rank(game(spot: "BUF 12", down: 2, distance: 4)).reason == "Red zone · 2nd & 4")
    #expect(rank(game(spot: "BUF 34", down: 4, distance: 2)).reason == "4th & 2 at BUF 34")
    #expect(rank(game(kc: 17, buf: 10, period: 4, clock: "2:11", spot: "KC 30")).reason
            == "One-score game, 2:11 left")
    #expect(rank(game(kc: 20, buf: 20, period: 4, clock: "0:48", spot: "KC 30")).reason
            == "Tied, 0:48 left")
    #expect(rank(game(period: 2, clock: "1:30", spot: "KC 30")).reason == "Two-minute drill · KC ball")
    #expect(rank(game(spot: "BUF 45")).reason == "KC ball · 1st & 10 at BUF 45")
}

@Test func redZoneReasonNamesTheFantasyStarter() {
    let quiet = game(spot: "KC 30")
    #expect(rank(quiet, FantasyLeverage(mineOnOffense: 1, leadName: "T. Kelce", leadIsMine: true)).reason
            == "Your T. Kelce on offense")
    let billsBall = game(ball: "2", spot: "BUF 30")
    #expect(rank(billsBall, FantasyLeverage(theirsOnOffense: 1, leadName: "J. Allen")).reason
            == "Opp's J. Allen on offense")
}

/// Only a score or turnover from the last minute and a half counts, and it fades out.
@Test func redZoneRecentMomentLeadsUntilItFades() {
    let quiet = game(spot: "KC 30")
    let fresh = rank(quiet, recent: moment("TD BUF · J. Cook 5-yd run", age: 10))
    #expect(fresh.reason == "TD BUF · J. Cook 5-yd run")
    #expect(approx(fresh.score, 10 + 15 * (1 - 10.0 / 90)))

    #expect(approx(rank(quiet, recent: moment("TD BUF", age: 90)).score, 10))
    #expect(approx(rank(quiet, recent: moment("KC in the red zone", kind: .redZone, age: 5)).score, 10))
    var otherGame = moment("TD BUF", age: 5)
    otherGame.gameID = "G9"
    #expect(approx(rank(quiet, recent: otherGame).score, 10))
}

/// The clock is worth saying in a close fourth quarter even when something else leads,
/// as long as the line stays short.
@Test func redZoneReasonAddsTheClockWhenItFits() {
    let redZone = game(kc: 17, buf: 14, period: 4, clock: "2:11", spot: "BUF 12", down: 2, distance: 4)
    #expect(rank(redZone).reason == "Red zone · 2nd & 4 · 2:11 left")

    let starter = FantasyLeverage(mineOnOffense: 3, leadName: "T. Kelce", leadIsMine: true)
    let ranked = rank(game(kc: 17, buf: 10, period: 4, clock: "9:00", spot: "KC 30"), starter)
    #expect(ranked.reason == "Your T. Kelce on offense")
}

// MARK: - Spotlight

private func ranked(_ id: String, _ score: Double, inPlay: Bool = true, redZone: Bool = false) -> RankedGame {
    RankedGame(id: id, score: score, reason: "", inPlay: inPlay, inRedZone: redZone)
}

@Test func redZoneSpotlightHoldsUntilTheMarginIsCleared() {
    #expect(RedZoneRanker.spotlight([ranked("A", 40), ranked("B", 47)], current: "A") == "A")
    #expect(RedZoneRanker.spotlight([ranked("A", 40), ranked("B", 48)], current: "A") == "B")
}

/// A game inside the 20 is about to produce something; it takes more to pull away.
@Test func redZoneSpotlightHoldsHarderInsideTheTwenty() {
    let a = ranked("A", 40, redZone: true)
    #expect(RedZoneRanker.spotlight([a, ranked("B", 54)], current: "A") == "A")
    #expect(RedZoneRanker.spotlight([a, ranked("B", 55)], current: "A") == "B")
}

@Test func redZoneSpotlightLeavesAGameThatEndedOrPaused() {
    // Final games are not ranked at all.
    #expect(RedZoneRanker.spotlight([ranked("B", 12)], current: "A") == "B")
    // At a break while another game is in play, even one ranked lower.
    let paused = ranked("A", 30, inPlay: false)
    #expect(RedZoneRanker.spotlight([paused, ranked("B", 3)], current: "A") == "B")
    // Nothing else in play: stay.
    #expect(RedZoneRanker.spotlight([paused, ranked("B", 3, inPlay: false)], current: "A") == "A")
}

@Test func redZoneSpotlightBreaksTiesByCurrentThenFavoriteThenID() {
    #expect(RedZoneRanker.spotlight([ranked("B", 20), ranked("A", 20)], current: "B") == "B")
    #expect(RedZoneRanker.spotlight([ranked("A", 20), ranked("B", 20)], current: nil,
                                    favoriteGameIDs: ["B"]) == "B")
    #expect(RedZoneRanker.spotlight([ranked("401772510", 20), ranked("401772509", 20)],
                                    current: nil) == "401772509")
    #expect(RedZoneRanker.spotlight([], current: "A") == nil)
}

/// Real events clear the bar by themselves: a drive reaching the 20, a score.
@Test func redZoneSpotlightSwitchesOnRealEvents() {
    let a = game(id: "A", spot: "50")
    let b = game(id: "B", spot: "KC 30")
    #expect(RedZoneRanker.spotlight([rank(a), rank(b)], current: nil) == "A")

    let bInside = game(id: "B", spot: "BUF 18")
    #expect(RedZoneRanker.spotlight([rank(a), rank(bInside)], current: "A") == "B")

    var scored = moment("TD BUF", age: 0)
    scored.gameID = "B"
    #expect(RedZoneRanker.spotlight([rank(a), rank(b, recent: scored)], current: "A") == "B")
}

/// Two games both inside the 20, trading small edges every poll, must not ping-pong.
@Test func redZoneSpotlightNeverSwapsBetweenTwoJitteringRedZoneGames() {
    var seed: UInt64 = 0x5EED
    func jitter() -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Double(Int(seed >> 33) % 11) - 5   // -5...5
    }
    var current = RedZoneRanker.spotlight([ranked("A", 45, redZone: true), ranked("B", 45, redZone: true)],
                                          current: nil)
    let first = current
    // Include the worst case outright.
    var polls = [(-5.0, 5.0), (5.0, -5.0)]
    for _ in 0..<18 { polls.append((jitter(), jitter())) }
    for (da, db) in polls {
        let games = [ranked("A", 45 + da, redZone: true), ranked("B", 45 + db, redZone: true)]
        current = RedZoneRanker.spotlight(games, current: current)
        #expect(current == first)
    }
    #expect(polls.count == 20)
}

// MARK: - Text

@Test func redZonePillShowsScoreDownSpotAndClock() {
    let g = game(kc: 17, buf: 14, period: 4, clock: "2:11", spot: "BUF 12", down: 2, distance: 4)
    #expect(RedZoneText.pill(g) == "KC 17-14 BUF · 2&4 BUF 12 · Q4 2:11")
}

@Test func redZonePillAtHalftimeAndWithoutASituation() {
    #expect(RedZoneText.pill(game(kc: 17, buf: 14, period: 2, clock: "0:00", phase: .halftime))
            == "KC 17-14 BUF · HALF")
    #expect(RedZoneText.pill(game(kc: 17, buf: 14, period: 4, clock: "2:11", hasSituation: false))
            == "KC 17-14 BUF · Q4 2:11")
    #expect(RedZoneText.pill(game(kc: 27, buf: 24, period: 4, clock: "0:00", phase: .final))
            == "KC 27-24 BUF · FINAL")
}

@Test func redZoneCompactDownWritesGoalAsG() {
    #expect(RedZoneText.compactDown(Situation(down: 2, distance: 4)) == "2&4")
    #expect(RedZoneText.compactDown(Situation(shortDownDistance: "3rd & Goal", down: 3, distance: 3)) == "3&G")
    #expect(RedZoneText.compactDown(Situation(shortDownDistance: "1st & 10", down: 1)) == "1&10")
    #expect(RedZoneText.compactDown(Situation(shortDownDistance: " & Goal", down: 0)) == nil)
    #expect(RedZoneText.compactDown(Situation()) == nil)
}

// MARK: - Stoppages

private func stoppedGame(id: String, typeID: String, text: String) -> Game {
    Game(id: id, shortName: "MIA @ MIN", phase: .live, statusDetail: "", period: 2,
         displayClock: "7:08",
         home: TeamSide(id: "16", abbreviation: "MIN", displayName: "MIN", shortName: "MIN", score: 6),
         away: TeamSide(id: "15", abbreviation: "MIA", displayName: "MIA", shortName: "MIA", score: 0),
         situation: Situation(isRedZone: true, lastPlayText: text, lastPlayID: "t", lastPlayTypeID: typeID))
}

/// Recorded live: an official timeout drops possession and the down but leaves
/// `isRedZone` set. Nothing is happening, so it is a break, not a moment.
@Test func redZoneTreatsTimeoutsAsBreaks() throws {
    let now = Date()
    let official = try #require(RedZoneRanker.rank(
        stoppedGame(id: "1", typeID: "74", text: "Official Timeout at 07:08."), now: now))
    #expect(!official.inPlay)
    #expect(official.reason == "Official timeout")

    let team = try #require(RedZoneRanker.rank(
        stoppedGame(id: "2", typeID: "21", text: "Timeout #2 by MIN at 07:08."), now: now))
    #expect(!team.inPlay)
    #expect(team.reason == "MIN timeout")
}

/// A game in a timeout hands the spotlight to any game with the ball live, at once.
@Test func redZoneLeavesAGameInATimeout() {
    let stopped = RankedGame(id: "1", score: 2, reason: "Official timeout", inPlay: false, inRedZone: false)
    let live = RankedGame(id: "2", score: 12, reason: "KC ball", inPlay: true, inRedZone: false)
    #expect(RedZoneRanker.spotlight([stopped, live], current: "1") == "2")
}

// MARK: - Following the action

private func midfield(id: String, ytg: Int, down: Int) -> Game {
    let spot = ytg > 50 ? "KC \(100 - ytg)" : "LV \(ytg)"
    return Game(id: id, shortName: "KC @ LV", phase: .live, statusDetail: "", period: 2,
                displayClock: "5:30",
                home: TeamSide(id: "13", abbreviation: "LV", displayName: "LV", shortName: "LV", score: 7),
                away: TeamSide(id: "12", abbreviation: "KC", displayName: "KC", shortName: "KC", score: 7),
                situation: Situation(possessionTeamID: "12", shortDownDistance: "\(down)st & 10",
                                     possessionText: spot, down: down, distance: 10,
                                     lastPlayID: "\(id)-p"))
}

/// Recorded live: four games between the 20s all scored 10–23, the margin was never
/// beaten, and the window sat on one game. A snap that just happened takes over.
@Test func redZoneFollowsTheGameThatJustSnapped() throws {
    let now = Date()
    let current = try #require(RedZoneRanker.rank(midfield(id: "1", ytg: 28, down: 3),
                                                  lastSnapAge: 40, now: now))
    let snapped = try #require(RedZoneRanker.rank(midfield(id: "2", ytg: 58, down: 1),
                                                  lastSnapAge: 1, now: now))
    #expect(RedZoneRanker.spotlight([current, snapped], current: "1", heldFor: 30) == "2")
}

/// A drive inside the 20 still holds between its own snaps against a fresh snap at midfield.
@Test func redZoneHoldsARedZoneDriveBetweenSnaps() throws {
    let now = Date()
    let goalLine = try #require(RedZoneRanker.rank(midfield(id: "1", ytg: 8, down: 2),
                                                   lastSnapAge: 30, now: now))
    let snapped = try #require(RedZoneRanker.rank(midfield(id: "2", ytg: 58, down: 1),
                                                  lastSnapAge: 1, now: now))
    #expect(RedZoneRanker.spotlight([goalLine, snapped], current: "1", heldFor: 30) == "1")
}

/// Freshly featured, a game is kept long enough to read the play.
@Test func redZoneDwellsBeforeCuttingAway() throws {
    let now = Date()
    let current = try #require(RedZoneRanker.rank(midfield(id: "1", ytg: 58, down: 1),
                                                  lastSnapAge: 6, now: now))
    let snapped = try #require(RedZoneRanker.rank(midfield(id: "2", ytg: 28, down: 3),
                                                  lastSnapAge: 0, now: now))
    #expect(RedZoneRanker.spotlight([current, snapped], current: "1", heldFor: 3) == "1")
    #expect(RedZoneRanker.spotlight([current, snapped], current: "1", heldFor: 9) == "2")
}
