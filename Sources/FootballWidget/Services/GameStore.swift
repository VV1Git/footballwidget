import Foundation
import Observation
import FootballCore

/// Single source of truth for the UI: the slate, the focused game's play feed, and
/// the polling loop that keeps them current.
@MainActor
@Observable
final class GameStore {
    private(set) var games: [Game] = []
    /// Kept as its own property rather than derived from `games`, so the always-mounted
    /// menu bar label and the app's scene only update when the count moves — not every
    /// time a clock ticks in one of the games.
    private(set) var liveCount = 0
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
            reschedule()
        }
    }

    private let feed: GameFeed
    private let alerts: AlertEngine
    private let preferences: Preferences
    @ObservationIgnored private var loop: Task<Void, Never>?
    /// The sleep between polls, held on its own so a focus change can cut it short
    /// without cancelling a fetch that is already on the wire.
    @ObservationIgnored private var nap: Task<Void, Never>?
    @ObservationIgnored private var lastPoll: Date?

    /// One observable slot per game, rather than one dictionary of every game's feed.
    /// Writing `details[id]` notified every view that read the dictionary — for any
    /// game, and even when the feed was unchanged — so with fantasy tracking half the
    /// slate, the open panel re-rendered once per tracked feed on every poll.
    @ObservationIgnored private var detailSlots: [String: DetailSlot] = [:]
    @ObservationIgnored private var detailGate = FetchGate(freshness: RefreshPolicy.detailFreshness)
    /// Runs beside the poll loop rather than inside `refresh()`: the scoreboard poll is
    /// what notifications are cut from, and holding it back to wait on a play feed would
    /// slow the alerts to speed up the ladder.
    @ObservationIgnored private var catchUp: Task<Void, Never>?
    /// Game id → the newest play a catch-up gave up on. The feed did not have it after
    /// every try, so asking again on each poll would only repeat the misses; the game is
    /// left to the ordinary poll until the scoreboard names a different play.
    @ObservationIgnored private var abandonedCatchUps: [String: String] = [:]

    init(feed: GameFeed, preferences: Preferences = .shared, alerts: AlertEngine = AlertEngine()) {
        self.feed = feed
        self.preferences = preferences
        self.alerts = alerts
    }

    // MARK: - Derived state

    var liveGames: [Game] { games.filter(\.isLive) }
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

    /// Reading this from a view observes that one game's feed and nothing else.
    func detail(id: String) -> GameDetail? { slot(for: id).detail }

    /// Created on first read, so a view that asks before the feed has arrived is
    /// already observing the slot the feed will land in.
    private func slot(for id: String) -> DetailSlot {
        if let slot = detailSlots[id] { return slot }
        let slot = DetailSlot()
        detailSlots[id] = slot
        return slot
    }

    // MARK: - Lifecycle

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            await self?.runLoop()
        }
        Task { await loadTeams() }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        nap?.cancel()
        nap = nil
        catchUp?.cancel()
        catchUp = nil
    }

    private func runLoop() async {
        while !Task.isCancelled {
            await refresh()
            // Measured from when the poll finished, as the old sleep-after-refresh loop
            // was, so a slow round of fetches never raises the request rate.
            lastPoll = .now

            // Sleep until the next poll is due. A focus change cancels the nap and the
            // wait is worked out again against the new interval — polling at once if the
            // data is already older than the new view wants.
            while !Task.isCancelled {
                let interval = RefreshPolicy.interval(games: games, focus: focus)
                let wait = PollSchedule.delay(lastPoll: lastPoll, interval: interval.timeInterval)
                guard wait > 0 else { break }
                let sleeper = Task<Void, Never> { try? await Task.sleep(for: .seconds(wait)) }
                nap = sleeper
                await sleeper.value
                nap = nil
            }
        }
    }

    /// A focus change used to cancel the whole loop and start a new one. That cancelled
    /// whatever fetch was in flight (logged as bursts of NSURLError -999, and shown as
    /// "cancelled" in the footer), then made the new loop's first refresh bail out on
    /// `isRefreshing`, and cost a full refresh for every open and close of the panel.
    /// Waking the nap does none of that.
    private func reschedule() {
        nap?.cancel()
    }

    // MARK: - Fetching

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            if case .updated(let fresh) = try await feed.scoreboard() {
                let previous = games
                // Assigning an equal value does not notify observers, so an unchanged
                // slate costs nothing here.
                games = fresh
                liveCount = fresh.reduce(0) { $0 + ($1.isLive ? 1 : 0) }
                lastUpdated = .now
                await alerts.process(previous: previous, current: fresh, preferences: preferences)
            } else {
                lastUpdated = .now
            }
            errorMessage = nil
        } catch let error where Self.isCancellation(error) {
            // Not a failure worth showing; the next poll runs as normal.
        } catch {
            errorMessage = error.localizedDescription
        }

        await refreshDetails(detailsDue())
        scheduleCatchUp()
    }

    // MARK: - Play feed catch-up

    /// The games whose play feed is a play short of the scoreboard, among those the
    /// panel or the fantasy layer is actually using.
    private func laggingFeeds() -> [String] {
        var ids = trackedGameIDs
        if let focused = RefreshPolicy.shouldFetchDetail(for: focus) { ids.insert(focused) }
        return ids.sorted().filter { id in
            guard let game = game(id: id), game.isLive,
                  let latest = game.situation?.lastPlayID, !latest.isEmpty,
                  abandonedCatchUps[id] != latest
            else { return false }
            return TrackedFeedPolicy.isBehind(latestPlayID: latest, held: detailSlots[id]?.detail)
        }
    }

    /// ESPN's scoreboard names a game's newest play a few seconds before its play feed
    /// carries it. The poll fetches the feed straight after the scoreboard, so it
    /// usually misses; the next look was a whole poll away, and a notification, cut from
    /// the scoreboard, beat the ladder by that long. This asks again every second and a
    /// half until the feed has the play.
    private func scheduleCatchUp() {
        guard catchUp == nil, !laggingFeeds().isEmpty else { return }
        catchUp = Task { [weak self] in
            for _ in 0..<RefreshPolicy.feedCatchUpAttempts {
                try? await Task.sleep(for: .seconds(RefreshPolicy.feedCatchUpDelay))
                guard let self, !Task.isCancelled else { return }
                let lagging = self.laggingFeeds()
                if lagging.isEmpty { break }
                await self.refreshDetails(lagging, retry: true)
            }
            self?.finishCatchUp()
        }
    }

    private func finishCatchUp() {
        for id in laggingFeeds() {
            abandonedCatchUps[id] = game(id: id)?.situation?.lastPlayID
        }
        catchUp = nil
    }

    /// The play feeds worth fetching this poll.
    ///
    /// The game on screen is fetched every poll, as the refresh table promises. A game
    /// that is only tracked for fantasy is fetched when the scoreboard shows a play its
    /// feed does not have yet — see `TrackedFeedPolicy`.
    private func detailsDue(now: Date = .now) -> [String] {
        var due: [String] = []
        let focused = RefreshPolicy.shouldFetchDetail(for: focus)
        if let focused { due.append(focused) }

        for id in trackedGameIDs.sorted() where id != focused {
            // Only live games can have produced a new play since the last poll.
            guard let game = game(id: id), game.isLive else { continue }
            if TrackedFeedPolicy.shouldFetch(
                latestPlayID: game.situation?.lastPlayID,
                held: detailSlots[id]?.detail,
                lastFetched: detailGate.lastStarted(id),
                maxAge: RefreshPolicy.trackedFeedMaxAge,
                now: now
            ) {
                due.append(id)
            }
        }
        return due
    }

    /// A few at a time rather than one after another; the client decodes them in turn.
    private func refreshDetails(_ ids: [String], retry: Bool = false) async {
        guard !ids.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            var pending = ids.makeIterator()
            for _ in 0..<RefreshPolicy.detailFetchConcurrency {
                guard let id = pending.next() else { break }
                group.addTask { await self.refreshDetail(id: id, retry: retry) }
            }
            while await group.next() != nil {
                guard let id = pending.next() else { continue }
                group.addTask { await self.refreshDetail(id: id, retry: retry) }
            }
        }
    }

    /// `retry` is a catch-up's follow-up fetch, which is deliberately soon after the one
    /// that missed, so it is not held to the freshness window. See `FetchGate.beginRetry`.
    func refreshDetail(id: String, retry: Bool = false) async {
        // Opening a game, the poll loop and a pinned window's loop all ask for feeds on
        // their own schedules; a fetch already running or just made is shared.
        guard retry ? detailGate.beginRetry(id) : detailGate.begin(id) else { return }
        defer { detailGate.end(id) }

        do {
            if case .updated(let detail) = try await feed.summary(gameID: id) {
                // An equal feed does not notify, so only a new play redraws the ladder.
                slot(for: id).detail = detail
            }
        } catch let error where Self.isCancellation(error) {
            return
        } catch {
            // A missing play feed is not worth surfacing over the whole panel — the
            // score and clock in the header are still good.
            NSLog("[FootballWidget] detail fetch failed for \(id): \(error.localizedDescription)")
        }
    }

    private func loadTeams() async {
        teams = (try? await feed.allTeams()) ?? []
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }
}

/// One game's play feed, observable on its own. See `GameStore.detailSlots`.
@MainActor
@Observable
final class DetailSlot {
    var detail: GameDetail?
}

private extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
