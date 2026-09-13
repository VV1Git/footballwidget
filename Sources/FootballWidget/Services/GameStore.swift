import Foundation
import Observation
import FootballCore

/// Single source of truth for the UI: the slate, the focused game's play feed, and
/// the polling loop that keeps them current.
@MainActor
@Observable
final class GameStore {
    private(set) var games: [Game] = []
    private(set) var details: [String: GameDetail] = [:]
    private(set) var teams: [ESPNClient.Team] = []
    private(set) var lastUpdated: Date?
    private(set) var errorMessage: String?
    private(set) var isRefreshing = false

    /// Games the fantasy layer needs play-by-play for, because one of your players or
    /// your opponent's is in them. Their feeds are pulled alongside the focused game so
    /// a notification can quote the actual play even for a game you are not watching.
    var trackedGameIDs: Set<String> = []

    /// Set by the UI so the poll rate can follow what is actually on screen.
    var focus: RefreshPolicy.Focus = .closed {
        didSet {
            guard focus != oldValue else { return }
            restartLoop()
        }
    }

    private let feed: GameFeed
    private let alerts: AlertEngine
    private let preferences: Preferences
    private var loop: Task<Void, Never>?

    init(feed: GameFeed, preferences: Preferences = .shared, alerts: AlertEngine = AlertEngine()) {
        self.feed = feed
        self.preferences = preferences
        self.alerts = alerts
    }

    // MARK: - Derived state

    var liveGames: [Game] { games.filter(\.isLive) }
    var liveCount: Int { liveGames.count }
    var hasGamesToday: Bool { !games.isEmpty }
    var nextKickoff: Date? { RefreshPolicy.nextKickoff(games: games) }

    /// Live first, then upcoming, then finals; favorites float to the top of each
    /// group. The comparator lives in `GameOrdering` so it can be tested.
    var sortedGames: [Game] {
        GameOrdering.sorted(games, favorites: preferences.favorites)
    }

    func isFavorite(_ game: Game) -> Bool {
        GameOrdering.isFavorite(game, preferences.favorites)
    }

    func game(id: String) -> Game? { games.first { $0.id == id } }
    func detail(id: String) -> GameDetail? { details[id] }

    // MARK: - Lifecycle

    func start() {
        guard loop == nil else { return }
        restartLoop()
        Task { await loadTeams() }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    private func restartLoop() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                guard let self else { return }
                let wait = RefreshPolicy.interval(games: games, focus: focus)
                try? await Task.sleep(for: wait)
            }
        }
    }

    // MARK: - Fetching

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            if case .updated(let fresh) = try await feed.scoreboard() {
                let previous = games
                games = fresh
                lastUpdated = .now
                await alerts.process(previous: previous, current: fresh, preferences: preferences)
            } else {
                lastUpdated = .now
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }

        // The game being looked at, plus any the fantasy layer is tracking.
        var wanted = trackedGameIDs
        if let id = RefreshPolicy.shouldFetchDetail(for: focus) { wanted.insert(id) }
        // Only live games can have produced a new play since the last poll.
        let live = Set(games.filter(\.isLive).map(\.id))
        for id in wanted where live.contains(id) || RefreshPolicy.shouldFetchDetail(for: focus) == id {
            await refreshDetail(id: id)
        }
    }

    func refreshDetail(id: String) async {
        do {
            if case .updated(let detail) = try await feed.summary(gameID: id) {
                details[id] = detail
            }
        } catch {
            // A missing play feed is not worth surfacing over the whole panel — the
            // score and clock in the header are still good.
            NSLog("[FootballWidget] detail fetch failed for \(id): \(error.localizedDescription)")
        }
    }

    private func loadTeams() async {
        teams = (try? await feed.allTeams()) ?? []
    }
}
