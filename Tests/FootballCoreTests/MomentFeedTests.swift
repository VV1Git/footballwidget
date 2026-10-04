import Foundation
import Testing
@testable import FootballCore

// MARK: - Builders

private let start = Date(timeIntervalSince1970: 1_800_000_000)

private func team(_ abbr: String, id: String, score: Int) -> TeamSide {
    TeamSide(id: id, abbreviation: abbr, displayName: abbr, shortName: abbr, score: score)
}

private func live(
    id: String = "G1", home: Int = 0, away: Int = 0,
    possession: String? = "H", redZone: Bool = false,
    lastPlayID: String? = nil, turnover: Bool = false,
    phase: GamePhase = .live, period: Int = 3, clock: String = "4:12",
    spot: String? = "AWY 40"
) -> Game {
    Game(
        id: id, shortName: "AWY @ HOM", phase: phase, statusDetail: "",
        period: period, displayClock: clock,
        home: team("HOM", id: "H", score: home),
        away: team("AWY", id: "A", score: away),
        situation: Situation(
            possessionTeamID: possession, possessionText: spot, down: 1, distance: 10,
            isRedZone: redZone, lastPlayText: "A play happened", lastPlayID: lastPlayID,
            lastPlayWasTurnover: turnover
        )
    )
}

// MARK: - Tests

/// A game already 7–0 when the app starts has nothing to compare against; the feed must
/// not open with a backlog.
@Test func momentFirstSightingIsSilent() {
    var feed = MomentFeed()
    let changed = feed.ingest([live(home: 7)], now: start)
    #expect(!changed)
    #expect(feed.moments.isEmpty)
}

@Test func momentIsStampedWithGameTeamAndClock() throws {
    var feed = MomentFeed()
    feed.ingest([live()], now: start)
    let changed = feed.ingest([live(home: 3)], now: start + 10)
    #expect(changed)

    let moment = try #require(feed.moments.first)
    #expect(moment.id == "G1|score-G1-3-0")
    #expect(moment.gameID == "G1")
    #expect(moment.kind == .scoring)
    #expect(moment.title == "FG HOM")
    #expect(moment.detail == "HOM 3–0 AWY · Q3 4:12")
    #expect(moment.teamID == "H")
    #expect(moment.clock == "Q3 4:12")
    #expect(moment.at == start + 10)
}

/// A turnover belongs to the team that has the ball afterwards.
@Test func momentTurnoverNamesTheTeamWithTheBall() throws {
    var feed = MomentFeed()
    feed.ingest([live(lastPlayID: "p1")], now: start)
    feed.ingest([live(possession: "A", lastPlayID: "p2", turnover: true, spot: "HOM 30")], now: start + 10)

    let moment = try #require(feed.moments.first)
    #expect(moment.kind == .turnover)
    #expect(moment.teamID == "A")
    #expect(moment.title == "Turnover · AWY ball")
    #expect(feed.latest(gameID: "G1") == moment)
}

/// The rules fire again for a second trip inside the 20 at the same score; it is the
/// same moment as far as the feed is concerned.
@Test func momentIsNotRepeated() {
    var feed = MomentFeed()
    feed.ingest([live()], now: start)
    let changed = feed.ingest([live(redZone: true, spot: "AWY 15")], now: start + 10)
    #expect(changed)
    feed.ingest([live(redZone: false, spot: "AWY 22")], now: start + 20)
    let changed2 = feed.ingest([live(redZone: true, spot: "AWY 18")], now: start + 30)
    #expect(!changed2)
    #expect(feed.moments.map(\.id) == ["G1|redzone-G1-H-0-0"])
    #expect(feed.moments.first?.teamID == "H")
}

@Test func momentFeedKeepsTheNewestThirty() {
    var feed = MomentFeed()
    feed.ingest([live()], now: start)
    for kick in 1...35 {
        feed.ingest([live(home: 3 * kick)], now: start + Double(kick) * 10)
    }
    #expect(feed.moments.count == MomentFeed.capacity)
    #expect(feed.moments.first?.id == "G1|score-G1-105-0")
    #expect(feed.moments.last?.id == "G1|score-G1-18-0")
    #expect(zip(feed.moments, feed.moments.dropFirst()).allSatisfy { $0.at > $1.at })
}

/// After the Mac sleeps through a quarter, the snapshots are stale; comparing against
/// them would read a quarter of football as one moment.
@Test func momentFeedIsSilentAfterAGap() {
    var feed = MomentFeed()
    feed.ingest([live()], now: start)
    let changed = feed.ingest([live(home: 7)], now: start + 200)
    #expect(!changed)
    #expect(feed.moments.isEmpty)
    let changed2 = feed.ingest([live(home: 10)], now: start + 210)
    #expect(changed2)
    #expect(feed.moments.first?.title == "FG HOM")
}

/// Identical polls still count as having looked, so a quiet spell is not a gap.
@Test func momentFeedUnchangedPollsKeepTheClockAlive() {
    var feed = MomentFeed()
    feed.ingest([live()], now: start)
    feed.scoreboardUnchanged(now: start + 100)
    let changed = feed.ingest([live(home: 7)], now: start + 200)
    #expect(changed)
}

@Test func momentFinalIsAnnouncedOnce() throws {
    var feed = MomentFeed()
    feed.ingest([live(home: 10, away: 7)], now: start)
    let final = live(home: 10, away: 7, phase: .final, period: 4, clock: "0:00")
    let changed = feed.ingest([final], now: start + 10)
    #expect(changed)

    let moment = try #require(feed.moments.first)
    #expect(moment.id == "G1|final")
    #expect(moment.kind == .final)
    #expect(moment.title == "Final · HOM 10–7 AWY")
    #expect(moment.teamID == "H")
    #expect(moment.clock == "FINAL")
    let changed2 = feed.ingest([final], now: start + 20)
    #expect(!changed2)
    #expect(feed.moments.count == 1)
    // The ranker's "just happened" is about plays, not results.
    #expect(feed.latest(gameID: "G1") == nil)
}

/// A game first seen already over did not end on our watch.
@Test func momentFinalNeedsTheGameSeenLive() {
    var feed = MomentFeed()
    let changed = feed.ingest([live(home: 10, phase: .final, period: 4, clock: "0:00")], now: start)
    #expect(!changed)
    let changed2 = feed.ingest([live(home: 10, phase: .final, period: 4, clock: "0:00")], now: start + 10)
    #expect(!changed2)
}

/// A game that drops off the slate and comes back is seen afresh.
@Test func momentFeedForgetsDroppedGames() {
    var feed = MomentFeed()
    feed.ingest([live()], now: start)
    feed.ingest([], now: start + 10)
    let changed = feed.ingest([live(home: 3)], now: start + 20)
    #expect(!changed)
    #expect(feed.moments.isEmpty)
}

/// Each game is compared with its own last poll, and the latest scoring moment is
/// looked up per game, skipping red-zone trips.
@Test func momentLatestIsPerGameAndSkipsRedZone() {
    var feed = MomentFeed()
    feed.ingest([live(id: "G1"), live(id: "G2")], now: start)
    feed.ingest([live(id: "G1", home: 3), live(id: "G2")], now: start + 10)
    feed.ingest([live(id: "G1", home: 3, redZone: true, spot: "AWY 12"), live(id: "G2")], now: start + 20)

    #expect(feed.moments.map(\.kind) == [.redZone, .scoring])
    #expect(feed.latest(gameID: "G1")?.id == "G1|score-G1-3-0")
    #expect(feed.latest(gameID: "G2") == nil)
}
