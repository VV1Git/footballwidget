import Foundation
import Testing
@testable import FootballCore

private func game(
    _ name: String, _ phase: GamePhase, kickoff: Date?,
    home: String = "HOM", away: String = "AWY"
) -> Game {
    Game(
        id: name, shortName: name, kickoff: kickoff, phase: phase,
        statusDetail: "", period: 0, displayClock: "",
        home: TeamSide(id: "1", abbreviation: home, displayName: home, shortName: home, score: 0),
        away: TeamSide(id: "2", abbreviation: away, displayName: away, shortName: away, score: 0)
    )
}

private func date(_ day: Int, _ hour: Int) -> Date {
    var parts = DateComponents()
    parts.year = 2026; parts.month = 9; parts.day = day; parts.hour = hour
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar.date(from: parts)!
}

@Test func liveGamesComeFirstThenUpcomingThenFinals() {
    let games = [
        game("FINAL", .final, kickoff: date(9, 20)),
        game("SOON", .pre, kickoff: date(13, 17)),
        game("LIVE", .live, kickoff: date(10, 20)),
    ]
    let order = GameOrdering.sorted(games, favorites: []).map(\.shortName)
    #expect(order == ["LIVE", "SOON", "FINAL"])
}

@Test func upcomingGamesRunInKickoffOrder() {
    let games = [
        game("MON", .pre, kickoff: date(14, 0)),
        game("THU", .pre, kickoff: date(10, 20)),
        game("SUN", .pre, kickoff: date(13, 17)),
    ]
    let order = GameOrdering.sorted(games, favorites: []).map(\.shortName)
    #expect(order == ["THU", "SUN", "MON"])
}

/// The bug this file exists for. Eight Sunday games share a kickoff time, and the old
/// comparator broke ties on a different key — making it intransitive, so Swift's sort
/// returned an arbitrary order and Monday night could surface above Sunday afternoon.
@Test func aFullSundaySlateSortsCorrectly() {
    var games = (1...8).map { game("SUN\($0)", .pre, kickoff: date(13, 17)) }
    games.append(game("LATE", .pre, kickoff: date(13, 20)))
    games.append(game("MON", .pre, kickoff: date(14, 0)))
    games.append(game("THU", .pre, kickoff: date(10, 20)))

    let order = GameOrdering.sorted(games.shuffled(), favorites: []).map(\.shortName)
    #expect(order.first == "THU")
    #expect(order.suffix(2) == ["LATE", "MON"])
    #expect(Array(order.dropFirst().prefix(8)) == (1...8).map { "SUN\($0)" })
}

/// A valid strict weak ordering: never both a<b and b<a, and the result must not
/// depend on the order the games arrived in.
@Test func orderingIsStableRegardlessOfInputOrder() {
    var games = (1...8).map { game("SUN\($0)", .pre, kickoff: date(13, 17)) }
    games.append(game("MON", .pre, kickoff: date(14, 0)))
    games.append(game("LIVE", .live, kickoff: date(13, 17)))
    games.append(game("DONE", .final, kickoff: date(9, 20)))

    let reference = GameOrdering.sorted(games, favorites: ["HOM"]).map(\.shortName)
    for _ in 0..<40 {
        #expect(GameOrdering.sorted(games.shuffled(), favorites: ["HOM"]).map(\.shortName) == reference)
    }

    for a in games {
        for b in games {
            let ab = GameOrdering.isOrdered(a, before: b, favorites: [])
            let ba = GameOrdering.isOrdered(b, before: a, favorites: [])
            #expect(!(ab && ba), "\(a.shortName) and \(b.shortName) each sort before the other")
        }
    }
}

// MARK: - Favorites

/// Starring a team lifts its game within its group — this is why a Monday night game
/// can legitimately sit above Sunday's slate.
@Test func favoritesRiseWithinTheirGroup() {
    let games = [
        game("SUN", .pre, kickoff: date(13, 17), home: "CIN", away: "TB"),
        game("MON", .pre, kickoff: date(14, 0), home: "KC", away: "DEN"),
        game("THU", .pre, kickoff: date(10, 20), home: "LAR", away: "SF"),
    ]
    let order = GameOrdering.sorted(games, favorites: ["DEN", "LAR"]).map(\.shortName)
    #expect(order == ["THU", "MON", "SUN"])
}

/// But never above a game that is actually being played.
@Test func favoritesDoNotOutrankALiveGame() {
    let games = [
        game("LIVE", .live, kickoff: date(13, 17), home: "CIN", away: "TB"),
        game("FAVE", .pre, kickoff: date(14, 0), home: "KC", away: "DEN"),
    ]
    let order = GameOrdering.sorted(games, favorites: ["DEN"]).map(\.shortName)
    #expect(order == ["LIVE", "FAVE"])
}

@Test func gamesWithNoKickoffSortLastNotFirst() {
    let games = [
        game("UNKNOWN", .pre, kickoff: nil),
        game("KNOWN", .pre, kickoff: date(13, 17)),
    ]
    let order = GameOrdering.sorted(games, favorites: []).map(\.shortName)
    #expect(order == ["KNOWN", "UNKNOWN"])
}
