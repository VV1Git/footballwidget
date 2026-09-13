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
        return .seconds(300)
    }

    static func nextKickoff(games: [Game], now: Date = .now) -> Date? {
        games
            .filter { $0.phase == .pre }
            .compactMap(\.kickoff)
            .filter { $0 > now }
            .min()
    }

    /// Whether the per-game play feed is worth pulling as well as the scoreboard.
    static func shouldFetchDetail(for focus: Focus) -> String? {
        if case .detail(let id) = focus { return id }
        return nil
    }
}
