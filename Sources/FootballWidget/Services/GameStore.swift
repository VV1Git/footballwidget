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

    /// Told about every scoreboard poll — `true` when the slate changed, `false` when the
    /// body came back identical. The RedZone feed listens, so it is warm before its window
    /// is ever shown.
    @ObservationIgnored var onScoreboard: (([Game], Bool) -> Void)?
    /// Told whenever a game's play feed arrives with something new, for the fantasy layer
    /// to score the new plays the moment they exist.
    @ObservationIgnored var onFeedUpdate: ((String, GameDetail) -> Void)?

    /// Who can have games on screen, each setting its own focus. One shared `focus`
    /// let the last writer win: closing the panel set it to `.closed` under a pinned
    /// window, and a closed pinned window left its game's focus on for good.
    enum FocusOwner: Hashable {
        case panel, redZone, pinned(String)
    }

    private let feed: GameFeed
    private let alerts: AlertEngine
    private let preferences: Preferences
    @ObservationIgnored private var loop: Task<Void, Never>?
    /// The sleep between polls, held on its own so a focus change can cut it short
    /// without cancelling a fetch that is already on the wire.
    @ObservationIgnored private var nap: Task<Void, Never>?
    @ObservationIgnored private var lastPoll: Date?
    /// What each open view is showing. The poll runs at the fastest rate any of them
    /// wants, and pulls the play feed of every game open in one.
    @ObservationIgnored private var foci: [FocusOwner: RefreshPolicy.Focus] = [:]
    /// Scoreboard polls failed in a row, and whether the last was ESPN refusing us
    /// (403/429). See `RefreshPolicy.retryInterval`.
    @ObservationIgnored private var scoreboardFailures = 0
    @ObservationIgnored private var scoreboardThrottled = false

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
    @ObservationIgnored private var lastTeamsAttempt: Date?
    /// Game id → the scoreboard's last play when it first said halftime. A different
    /// snap since then means the second half is under way, whatever the status says.
    @ObservationIgnored private var halftimeLastPlay: [String: String] = [:]
    /// Game id → play id → when the play first appeared in that game's feed. Fantasy
    /// points trail the feed, and this is how the fantasy layer tells a play still
    /// waiting for its points from one whose points are long in. Plays already in a feed
    /// the first time it arrives are dated `.distantPast`: they happened before anyone
    /// was watching.
    @ObservationIgnored private var playFirstSeen: [String: [String: Date]] = [:]

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

    /// Set by each view so the poll rate can follow what is actually on screen. `nil`
    /// means that view is gone.
    func setFocus(_ focus: RefreshPolicy.Focus?, for owner: FocusOwner) {
        let before = Set(foci.values)
        foci[owner] = focus
        if Set(foci.values) != before { reschedule() }
    }

    /// NFL banners hold off while RedZone is on screen, since it is already showing them.
    var isRedZoneVisible: Bool { foci[.redZone] != nil }

    /// Reading this from a view observes that one game's feed and nothing else.
    func detail(id: String) -> GameDetail? { slot(for: id).detail }

    /// When a play first showed up in its game's feed. See `playFirstSeen`.
    func firstSeen(playID: String, inGame gameID: String) -> Date? {
        playFirstSeen[gameID]?[playID]
    }

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
        Task { await alerts.requestAuthorization() }
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
                let wait = PollSchedule.delay(lastPoll: lastPoll, interval: pollInterval().timeInterval)
                guard wait > 0 else { break }
                let sleeper = Task<Void, Never> { try? await Task.sleep(for: .seconds(wait)) }
                nap = sleeper
                await sleeper.value
                nap = nil
            }
        }
    }

    private func pollInterval() -> Duration {
        RefreshPolicy.retryInterval(
            normal: RefreshPolicy.interval(games: games, foci: Array(foci.values)),
            failures: scoreboardFailures,
            throttled: scoreboardThrottled
        )
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
            if case .updated(let scoreboard) = try await feed.scoreboard() {
                let fresh = reconcile(scoreboard)
                let previous = games
                // Assigning an equal value does not notify observers, so an unchanged
                // slate costs nothing here.
                games = fresh
                liveCount = fresh.reduce(0) { $0 + ($1.isLive ? 1 : 0) }
                lastUpdated = .now
                // Per-game state follows the slate, so a launch-at-login app does not carry
                // every feed of the season around.
                let ids = Set(fresh.map(\.id))
                playFirstSeen = playFirstSeen.filter { ids.contains($0.key) }
                detailSlots = detailSlots.filter { ids.contains($0.key) }
                abandonedCatchUps = abandonedCatchUps.filter { ids.contains($0.key) }
                onScoreboard?(fresh, true)
                await alerts.process(
                    previous: previous, current: fresh, preferences: preferences,
                    muted: isRedZoneVisible
                )
            } else {
                lastUpdated = .now
                onScoreboard?(games, false)
                await alerts.scoreboardUnchanged()
            }
            errorMessage = nil
            retryTeamsIfNeeded()
            scoreboardFailures = 0
            scoreboardThrottled = false
        } catch let error where Self.isCancellation(error) {
            // Not a failure worth showing; the next poll runs as normal.
        } catch {
            errorMessage = error.localizedDescription
            scoreboardFailures += 1
            scoreboardThrottled = Self.isThrottled(error)
        }

        await refreshDetails(detailsDue())
        scheduleCatchUp()
    }

    // MARK: - Play feed catch-up

    /// The games whose play feed is a play short of the scoreboard, among those a view
    /// or the fantasy layer is actually using.
    private func laggingFeeds() -> [String] {
        let ids = trackedGameIDs.union(RefreshPolicy.detailGameIDs(Array(foci.values)))
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
    /// Games on screen are fetched every poll, as the refresh table promises. A game
    /// that is only tracked for fantasy is fetched when the scoreboard shows a play its
    /// feed does not have yet — see `TrackedFeedPolicy`.
    private func detailsDue(now: Date = .now) -> [String] {
        let focused = RefreshPolicy.detailGameIDs(Array(foci.values))
        var due = focused.sorted()

        for id in trackedGameIDs.sorted() where !focused.contains(id) {
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
        // ESPN refusing the scoreboard refuses the play feeds too, and a pinned window
        // asking every five seconds regardless would only prolong the block.
        guard !scoreboardThrottled else { return }
        // Opening a game, the poll loop and a pinned window's loop all ask for feeds on
        // their own schedules; a fetch already running or just made is shared.
        guard retry ? detailGate.beginRetry(id) : detailGate.begin(id) else { return }
        defer { detailGate.end(id) }

        do {
            if case .updated(let detail) = try await feed.summary(gameID: id) {
                recordFirstSeen(detail, gameID: id)
                // The feed's own status can be ahead of the scoreboard's; the header
                // moves on now rather than at the next scoreboard poll.
                let moved = games.map { $0.id == id ? $0.reconciled(with: detail.status) : $0 }
                if moved != games {
                    games = moved
                    liveCount = moved.reduce(0) { $0 + ($1.isLive ? 1 : 0) }
                }
                let isNew = slot(for: id).detail != detail
                // An equal feed does not notify, so only a new play redraws the ladder.
                slot(for: id).detail = detail
                if isNew { onFeedUpdate?(id, detail) }
            }
        } catch let error where Self.isCancellation(error) {
            return
        } catch {
            // A missing play feed is not worth surfacing over the whole panel — the
            // score and clock in the header are still good.
            NSLog("[FootballWidget] detail fetch failed for \(id): \(error.localizedDescription)")
        }
    }

    /// The scoreboard's slate, brought up to date where the play feeds know better.
    ///
    /// ESPN's scoreboard can keep saying "Halftime" for minutes into the third quarter
    /// while the play feed already carries its plays. A game with a feed in hand takes
    /// the feed's status when it is further along; a game without one is taken as live
    /// once a snap has happened since halftime began. Applied to every poll, so a stale
    /// scoreboard cannot put "HALF" back.
    private func reconcile(_ scoreboard: [Game]) -> [Game] {
        var halftime: [String: String] = [:]
        let games = scoreboard.map { game -> Game in
            if game.phase == .halftime {
                halftime[game.id] = halftimeLastPlay[game.id] ?? game.situation?.lastPlayID ?? ""
            }
            return game
                .reconciled(with: detailSlots[game.id]?.detail?.status)
                .resumedAfterHalftime(halftimeLastPlay: halftime[game.id])
        }
        halftimeLastPlay = halftime
        return games
    }

    private func recordFirstSeen(_ detail: GameDetail, gameID: String) {
        let now = Date.now
        let isFirstLook = playFirstSeen[gameID] == nil
        var seen = playFirstSeen[gameID] ?? [:]
        for drive in detail.drives {
            for play in drive.plays where seen[play.id] == nil {
                seen[play.id] = isFirstLook ? .distantPast : now
            }
        }
        playFirstSeen[gameID] = seen
    }

    /// Fetched once at launch, which with launch at login is often before the network is
    /// up — and a failure left the favourites picker on "Loading teams…" for good. Retried
    /// after any successful poll while the list is still empty, at most every few minutes.
    private func loadTeams() async {
        lastTeamsAttempt = .now
        let loaded = (try? await feed.allTeams()) ?? []
        if !loaded.isEmpty { teams = loaded }
    }

    private func retryTeamsIfNeeded() {
        guard teams.isEmpty else { return }
        if let lastTeamsAttempt, Date.now.timeIntervalSince(lastTeamsAttempt) < 180 { return }
        Task { await loadTeams() }
    }

    private static func isThrottled(_ error: Error) -> Bool {
        guard case .status(let code)? = error as? ESPNClient.ClientError else { return false }
        return code == 403 || code == 429
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
