import Foundation
import FootballCore

/// How often to poll, given what is on and what the user is looking at.
///
/// Polling hard all day would be rude to a free endpoint and pointless — nothing
/// changes between Tuesday and Sunday — so the interval tracks the actual state.
enum RefreshPolicy {

    /// What the user currently has open. Tighter views poll faster.
    enum Focus: Sendable, Hashable {
        case closed
        case list
        case detail(gameID: String)
        /// RedZone's expanded window. Everything it shows is on the scoreboard, so it
        /// polls that as often as an open game does but never pulls a play feed.
        case ticker
    }

    static func interval(games: [Game], focus: Focus, now: Date = .now) -> Duration {
        let live = games.contains { $0.isLive }

        if live {
            switch focus {
            case .detail, .ticker: return .seconds(5)
            case .list:            return .seconds(10)
            case .closed:          return .seconds(20)
            }
        }

        // ESPN holds a game at "pre" until the ball is actually kicked, often a few
        // minutes after the listed time. `nextKickoff` only looks ahead, so the wait
        // used to jump to five minutes or half an hour just as the game was starting.
        if games.contains(where: { isOverdue($0, now: now) }) { return .seconds(30) }

        guard let next = nextKickoff(games: games, now: now) else {
            return .seconds(1800)   // nothing today
        }

        let untilKickoff = next.timeIntervalSince(now)
        if untilKickoff < 600 { return .seconds(60) }       // final 10 minutes
        // Once the week's finals are behind us the slate is next week's, whose kickoff
        // can be two days out. Nothing about a Thursday game moves on a Tuesday, so
        // that waits at the same rate as an empty day rather than polling all week.
        if untilKickoff > 21_600 { return .seconds(1800) }  // more than six hours off
        return .seconds(300)
    }

    /// The fastest interval any open view wants. With nothing open it polls as `.closed`.
    static func interval(games: [Game], foci: [Focus], now: Date = .now) -> Duration {
        foci.map { interval(games: games, focus: $0, now: now) }.min()
            ?? interval(games: games, focus: .closed, now: now)
    }

    /// Past its listed kickoff and still not started. Only for three hours, so a game
    /// ESPN leaves at "pre" after a postponement cannot hold the poll at 30 s all day.
    private static func isOverdue(_ game: Game, now: Date) -> Bool {
        guard game.phase == .pre, let kickoff = game.kickoff else { return false }
        let late = now.timeIntervalSince(kickoff)
        return late >= 0 && late < 10_800
    }

    /// How long to wait after the scoreboard poll has failed `failures` times running.
    ///
    /// The ordinary interval trusts the last answer, and with nothing loaded at all it is
    /// the half-hour "nothing today" wait, so one failed poll at launch left the panel
    /// empty for thirty minutes. A failure now retries within 30 s, doubling to five
    /// minutes while it keeps failing, unless the ordinary interval is sooner. A 403 or
    /// 429 is ESPN saying slow down, and it has blocked this app for polling too hard
    /// before, so that waits at least a minute, doubling to ten, even mid-game.
    static func retryInterval(normal: Duration, failures: Int, throttled: Bool) -> Duration {
        guard failures > 0 else { return normal }
        let doublings = min(failures - 1, 5)
        var wait = min(normal, .seconds(min(30 << doublings, 300)))
        if throttled { wait = max(wait, .seconds(min(60 << doublings, 600))) }
        return wait
    }

    static func nextKickoff(games: [Game], now: Date = .now) -> Date? {
        games
            .filter { $0.phase == .pre }
            .compactMap(\.kickoff)
            .filter { $0 > now }
            .min()
    }

    /// How recently a game's play feed can have been fetched and still be reused
    /// rather than fetched again. Just under the fastest interval above, so overlapping
    /// callers (the poll loop, a pinned window, opening a game) share one fetch but a
    /// loop that is due is never starved.
    static let detailFreshness: TimeInterval = 4

    /// A game tracked only for fantasy, and not on screen, has its play feed fetched
    /// when the scoreboard reports a play the feed lacks — and otherwise at most this
    /// often. See `TrackedFeedPolicy`.
    static let trackedFeedMaxAge: TimeInterval = 60

    /// When the scoreboard names a play the feed lacks, the feed is asked again this
    /// often, this many times, rather than waiting a whole poll. Four tries at a second
    /// and a half covers the few seconds ESPN's feed usually trails by; past that the
    /// ordinary poll picks it up, and the game is left alone until its next new play.
    static let feedCatchUpDelay: TimeInterval = 1.5
    static let feedCatchUpAttempts = 4

    /// Play feeds fetched at once in one poll. The loop used to fetch them one after
    /// another, holding the next poll back by the whole round.
    static let detailFetchConcurrency = 3

    /// The games whose play feed is worth pulling as well as the scoreboard: every game
    /// open in a detail view, wherever it is open.
    static func detailGameIDs(_ foci: [Focus]) -> Set<String> {
        var ids: Set<String> = []
        for case .detail(let id) in foci { ids.insert(id) }
        return ids
    }
}
