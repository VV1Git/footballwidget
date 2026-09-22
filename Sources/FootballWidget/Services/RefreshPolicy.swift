import Foundation
import FootballCore

/// How often to poll, given what is on and what the user is looking at.
///
/// Polling hard all day would be rude to a free endpoint and pointless — nothing
/// changes between Tuesday and Sunday — so the interval tracks the actual state.
enum RefreshPolicy {

    /// What the user currently has open. Tighter views poll faster.
    enum Focus: Sendable, Equatable {
        case closed
        case list
        case detail(gameID: String)
    }

    static func interval(games: [Game], focus: Focus, now: Date = .now) -> Duration {
        let live = games.contains { $0.isLive }

        if live {
            switch focus {
            case .detail: return .seconds(5)
            case .list:   return .seconds(10)
            case .closed: return .seconds(20)
            }
        }

        guard let next = nextKickoff(games: games, now: now) else {
            return .seconds(1800)   // nothing today
        }

        let untilKickoff = next.timeIntervalSince(now)
        if untilKickoff <= 0 { return .seconds(30) }        // should be live any moment
        if untilKickoff < 600 { return .seconds(60) }       // final 10 minutes
        // Once the week's finals are behind us the slate is next week's, whose kickoff
        // can be two days out. Nothing about a Thursday game moves on a Tuesday, so
        // that waits at the same rate as an empty day rather than polling all week.
        if untilKickoff > 21_600 { return .seconds(1800) }  // more than six hours off
        return .seconds(300)
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

    /// Whether the per-game play feed is worth pulling as well as the scoreboard.
    static func shouldFetchDetail(for focus: Focus) -> String? {
        if case .detail(let id) = focus { return id }
        return nil
    }
}
