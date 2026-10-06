import Foundation
import Observation
import FootballCore

/// Kalshi's chance of each live game's favourite winning, for the RedZone window.
///
/// One request returns every NFL game Kalshi lists, priced, so a poll costs one call
/// however many games are on. It only runs while the RedZone window is showing.
@MainActor
@Observable
final class OddsStore {
    /// Game id → the favourite and its chance.
    private(set) var odds: [String: WinOdds] = [:]

    @ObservationIgnored weak var games: GameStore?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private let session: URLSession

    /// Market prices move with every snap, but a number in a corner does not need to
    /// keep up to the second.
    static let interval: Duration = .seconds(30)

    private static let url = URL(string:
        "https://api.elections.kalshi.com/trade-api/v2/events?series_ticker=KXNFLGAME&status=open&with_nested_markets=true&limit=100")!

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
    }

    /// A store with fixed odds, for offscreen rendering.
    static func preview(_ odds: [String: WinOdds]) -> OddsStore {
        let store = OddsStore()
        store.odds = odds
        return store
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    private func refresh() async {
        guard let games, !games.liveGames.isEmpty else { return }
        var request = URLRequest(url: Self.url)
        request.setValue("FootballWidget/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            let events = try JSONDecoder().decode(KalshiEventsDTO.self, from: data)
            var next: [String: WinOdds] = [:]
            for game in games.liveGames {
                next[game.id] = KalshiOdds.odds(for: game, in: events)
            }
            if next != odds { odds = next }
        } catch {
            // Odds are a nicety; a failed poll keeps the last ones and tries again.
            NSLog("[FootballWidget] odds fetch failed: \(error.localizedDescription)")
        }
    }
}
