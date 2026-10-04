import Foundation
import Testing
@testable import FootballCore

// MARK: - Builders

private func rostered(
    _ id: Int, _ first: String, _ last: String,
    _ position: FantasyPosition = .wideReceiver,
    team: Int = 26, points: Double = 0
) -> RosterPlayer {
    RosterPlayer(id: id, fullName: "\(first) \(last)", firstName: first, lastName: last,
                 position: position, slot: .starting(position.rawValue), proTeamID: team,
                 points: points, injuryStatus: nil)
}

private let jsn = rostered(4430878, "Jaxon", "Smith-Njigba")

private let shortCompletion = "(Shotgun) S.Darnold pass short middle to J.Smith-Njigba to SEA 40 for 10 yards (R.Spillane)."
private let touchdownPass = "S.Darnold pass short left to J.Smith-Njigba for 15 yards, TOUCHDOWN. J.Myers extra point is GOOD, Center-C.Stoll, Holder-M.Dickson."

// MARK: - Alerts

private func matchup(_ players: [RosterPlayer]) -> FantasyMatchup {
    let mine = FantasyTeam(id: 1, name: "Mine", abbreviation: "ME", points: 80, roster: players)
    let theirs = FantasyTeam(id: 2, name: "Theirs", abbreviation: "OP", points: 70, roster: [])
    return FantasyMatchup(leagueName: "League", week: 5, mine: mine, opponent: theirs)
}

/// The same play alerts once, however often it is scored again — its text corrected
/// from 10 yards to 13, say. Keyed to the running total, as it once was, every new total
/// was a new banner.
@Test func onePlayAlertsOnceHoweverOftenItIsScored() {
    let settings = FantasyAlertSettings(threshold: 3)
    let first = FantasyMoment(player: jsn, isMine: true, delta: 3.5, playText: shortCompletion,
                              isTouchdown: false, playID: "a", pointsOnPlay: 3.5)
    let followUp = FantasyMoment(player: jsn, isMine: true, delta: 3.8, playText: shortCompletion,
                                 isTouchdown: false, playID: "a", pointsOnPlay: 3.8)
    let one = FantasyAlertRules.events(moments: [first], matchup: matchup([jsn]),
                                       settings: settings, leagueID: "111")
    let two = FantasyAlertRules.events(moments: [followUp], matchup: matchup([jsn]),
                                       settings: settings, leagueID: "111")
    #expect(one.count == 1)
    #expect(one.first?.id == two.first?.id)

    var delivered = DeliveredLog()
    let firstDelivered = delivered.insert(one[0].id)
    let secondDelivered = delivered.insert(two[0].id)
    #expect(firstDelivered)
    #expect(!secondDelivered)

    // The same player in another league is a different alert.
    let otherLeague = FantasyAlertRules.events(moments: [first], matchup: matchup([jsn]),
                                               settings: settings, leagueID: "222")
    #expect(otherLeague.first?.id != one.first?.id)
}

@Test func theBannerShowsEverythingThePlayEarned() throws {
    let moment = FantasyMoment(player: jsn, isMine: true, delta: 6.0, playText: touchdownPass,
                               isTouchdown: true, playID: "b", pointsOnPlay: 9.5)
    let event = try #require(FantasyAlertRules.event(for: moment, matchup: matchup([jsn]),
                                                     settings: FantasyAlertSettings()))
    #expect(event.title.hasSuffix("+9.5"))
    #expect(event.body == "15-yd catch from S. Darnold")
}

@Test func correctionsNeverAlert() {
    let moment = FantasyMoment(player: jsn, isMine: true, delta: 8.0, playText: nil,
                               isTouchdown: false, isCorrection: true)
    #expect(FantasyAlertRules.events(moments: [moment], matchup: matchup([jsn]),
                                     settings: FantasyAlertSettings(threshold: 1)).isEmpty)
}

@Test func playLinesReadPlayersWithSuffixes() {
    let thomas = rostered(4686361, "Brian", "Thomas Jr.", team: 30)
    let moment = FantasyMoment(
        player: thomas, isMine: true, delta: 4.2,
        playText: "T.Lawrence pass short right to B.Thomas to JAX 45 for 32 yards (J.Bates).",
        isTouchdown: false
    )
    #expect(FantasyAlertRules.playLine(for: moment)?.hasPrefix("32-yd catch") == true)
}

// MARK: - Ledger

@Test func ledgerKeepsLeaguesAndGamesApart() {
    var ledger = FantasyLedger()
    ledger.replace(game: "g1", league: "A", with: ["p": [1: 3.9]])
    ledger.replace(game: "g1", league: "B", with: ["p": [1: 2.9]])
    ledger.replace(game: "g2", league: "A", with: ["q": [2: 6.0]])

    #expect(ledger.points(league: "A", game: "g1", play: "p", player: 1) == 3.9)
    #expect(ledger.points(league: "B", game: "g1", play: "p", player: 1) == 2.9)
    #expect(ledger.plays(league: "A", game: "g2") == ["q": [2: 6.0]])
    #expect(ledger.plays(league: "C", game: "g1").isEmpty)
}

/// A game scored again replaces what it had, so a corrected play's chip changes and a
/// play that no longer scores loses its chip.
@Test func ledgerReplacesAGameWholesale() {
    var ledger = FantasyLedger()
    ledger.replace(game: "g1", league: "A", with: ["p": [1: 3.9], "q": [1: 1.0]])
    ledger.replace(game: "g1", league: "A", with: ["p": [1: 4.4]])
    #expect(ledger.plays(league: "A", game: "g1") == ["p": [1: 4.4]])

    ledger.replace(game: "g1", league: "A", with: [:])
    #expect(ledger.isEmpty)
}

@Test func ledgerForgetsRemovedLeaguesAndFinishedGames() {
    var ledger = FantasyLedger()
    ledger.replace(game: "old", league: "A", with: ["p": [1: 3]])
    ledger.replace(game: "new", league: "A", with: ["q": [1: 3]])
    ledger.replace(game: "new", league: "B", with: ["r": [2: 3]])

    ledger.retainGames(["new"])
    #expect(ledger.plays(league: "A", game: "old").isEmpty)
    #expect(!ledger.plays(league: "A", game: "new").isEmpty)

    ledger.removeLeague("B")
    #expect(ledger.plays(league: "B", game: "new").isEmpty)
}

// MARK: - De-duplication

@Test func deliveredLogForgetsOldestFirst() {
    var log = DeliveredLog(capacity: 2)
    let inserted = ["a", "a", "b", "c"].map { log.insert($0) }
    #expect(inserted == [true, false, true, true])
    #expect(!log.contains("a"))
    #expect(log.contains("b") && log.contains("c"))
}

// MARK: - A pick-six announced once

private func game(home: Int, away: Int, lastPlayID: String, text: String,
                  possession: String? = "H", turnover: Bool = false) -> Game {
    Game(id: "G1", shortName: "AWY @ HOM", phase: .live, statusDetail: "", period: 3,
         displayClock: "5:00",
         home: TeamSide(id: "H", abbreviation: "HOM", displayName: "HOM", shortName: "HOM", score: home),
         away: TeamSide(id: "A", abbreviation: "AWY", displayName: "AWY", shortName: "AWY", score: away),
         situation: Situation(possessionTeamID: possession, down: 1, lastPlayText: text,
                              lastPlayID: lastPlayID, lastPlayWasTurnover: turnover))
}

private let pickSix = "(Shotgun) P.Mahomes pass short middle intended for J.Smith-Schuster INTERCEPTED by D.Lloyd at JAX 1. D.Lloyd for 99 yards, TOUCHDOWN. C.Little extra point is GOOD, Center-R.Matiscik, Holder-L.Cooke."

/// The score posts a poll before the play text: the plain "TD AWY" goes out then, and
/// the pick-six text arriving next must not announce the same touchdown again.
@Test func aPickSixIsNotAnnouncedAgainWhenTheScoreCameFirst() {
    let before = game(home: 7, away: 0, lastPlayID: "p1", text: "J.Doe up the middle to HOM 30 for 3 yards (X.Roe).")
    var snapshot = GameSnapshot(game: before)

    let scoreFirst = game(home: 7, away: 6, lastPlayID: "p1", text: before.situation!.lastPlayText!)
    let first = AlertRules.events(previous: snapshot, game: scoreFirst, settings: AlertSettings())
    #expect(first.map(\.kind) == [.scoring])
    snapshot = GameSnapshot(game: scoreFirst, previous: snapshot)

    let textNext = game(home: 7, away: 6, lastPlayID: "p2", text: pickSix, possession: "A", turnover: true)
    #expect(AlertRules.events(previous: snapshot, game: textNext, settings: AlertSettings()).isEmpty)

    // With scoring alerts off nothing announced the touchdown, so the turnover banner does.
    let turnoversOnly = AlertSettings(scoring: false)
    #expect(AlertRules.events(previous: snapshot, game: textNext, settings: turnoversOnly).count == 1)
}

/// The text posts first: the banner waits a poll for the score and carries the names.
@Test func aPickSixWhoseTextCameFirstIsAnnouncedOnceWithTheScore() {
    let before = game(home: 7, away: 0, lastPlayID: "p1", text: "J.Doe up the middle to HOM 30 for 3 yards (X.Roe).")
    var snapshot = GameSnapshot(game: before)

    let textFirst = game(home: 7, away: 0, lastPlayID: "p2", text: pickSix, possession: "A", turnover: true)
    let first = AlertRules.events(previous: snapshot, game: textFirst, settings: AlertSettings())
    snapshot = GameSnapshot(game: textFirst, previous: snapshot)

    let scoreNext = game(home: 7, away: 7, lastPlayID: "p2", text: pickSix, possession: "A", turnover: true)
    let second = AlertRules.events(previous: snapshot, game: scoreNext, settings: AlertSettings())

    let all = first + second
    #expect(all.count == 1)
    #expect(all.first?.title.contains("pick-six") == true)
}
