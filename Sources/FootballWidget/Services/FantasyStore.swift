import Foundation
import Observation
import FootballCore

/// Owns your fantasy matchup: polls the league for the matchup and its scoring table,
/// scores every play of your players' games as the play feed brings it in, and hands the
/// results to the views and the alert engine.
@MainActor
@Observable
final class FantasyStore {

    enum ConnectionState: Equatable {
        case notConfigured
        case connecting
        case connected
        case failed(String)

        var isConnected: Bool { self == .connected }
    }

    /// One matchup per connected league, keyed by league id.
    private(set) var matchups: [String: FantasyMatchup] = [:]
    /// Per-league connection state, so one bad league does not hide the others.
    private(set) var states: [String: ConnectionState] = [:]
    private(set) var lastUpdated: Date?

    /// Credits keyed by NFL play id, for the field map to draw chips from.
    private(set) var creditsByPlay: [String: [PlayAttribution.Credit]] = [:]

    /// Chance of winning per league, worked out when data arrives rather than in a view
    /// body. Absent when there is no opponent or nothing honest to show.
    private(set) var winProbabilities: [String: WinProbability] = [:]

    /// Per league: how the plays' own points compare with ESPN's totals. See
    /// `checkAgainstESPN`.
    private(set) var accuracy: [String: FantasyAccuracy] = [:]
    /// League id → player id → what his scored plays add up to in this game.
    @ObservationIgnored private var computedTotals: [String: [Int: Double]] = [:]
    /// "league|player" → when his figure and ESPN's first disagreed.
    @ObservationIgnored private var disagreeingSince: [String: Date] = [:]

    private let client: FantasyClient
    private let preferences: Preferences
    private let alerts: AlertEngine
    private weak var games: GameStore?

    /// What every play was worth, per league, for the chips. Worked out again from the
    /// feeds whenever they or the matchups change, so it needs no saving: a relaunch
    /// fills it back in, plays from before the launch included, as soon as the feeds load.
    @ObservationIgnored private var ledger = FantasyLedger()
    /// Game id → play id → the text last parsed and what it said. A feed is scored again
    /// on every change and every fantasy poll; only a new or rewritten play is parsed.
    @ObservationIgnored private var summaries: [String: [String: (text: String, summary: PlaySummary)]] = [:]
    /// Game id → the feed last read, the scorer built from it and each player's lines,
    /// reused while the feed is unchanged — which on most fantasy polls it is.
    @ObservationIgnored private var scored: [String: ScoredFeed] = [:]

    private struct ScoredFeed {
        var detail: GameDetail
        var scorer: FantasyGameScorer
        /// Player id → his stat line for every play. The same in every league; only the
        /// points differ.
        var lines: [Int: [FantasyPlayLine]] = [:]
    }
    /// Game id → "league|player|play" keys already judged for an alert, so a play is
    /// weighed once per player per league however often it is scored again.
    @ObservationIgnored private var judged: [String: Set<String>] = [:]
    /// Game id → the same keys for plays last seen under review, and when. The ruling is
    /// what gets judged, and it can come a few minutes after the play first appeared.
    @ObservationIgnored private var awaitingRuling: [String: [String: Date]] = [:]
    private var loop: Task<Void, Never>?

    init(client: FantasyClient = FantasyClient(),
         preferences: Preferences = .shared,
         alerts: AlertEngine) {
        self.client = client
        self.preferences = preferences
        self.alerts = alerts
    }

    /// A store pre-populated with a matchup, for offscreen rendering and previews.
    static func preview(matchup: FantasyMatchup) -> FantasyStore {
        let store = FantasyStore(alerts: AlertEngine())
        store.matchups["preview"] = matchup
        store.states["preview"] = .connected
        store.previewLeagueID = "preview"
        store.winProbabilities["preview"] = WinProbability.estimate(for: matchup) { _ in nil }
        return store
    }

    /// Set only by `preview(matchup:)`, so a rendered view has an active league
    /// without needing anything written to preferences.
    private var previewLeagueID: String?

    func attach(to games: GameStore) {
        self.games = games
        // A play is scored the moment its feed brings it in, rather than whenever ESPN's
        // fantasy totals next move.
        games.onFeedUpdate = { [weak self] gameID, detail in
            self?.feedUpdated(gameID: gameID, detail: detail)
        }
    }

    // MARK: - Derived

    var leagueIDs: [String] {
        if let previewLeagueID { return [previewLeagueID] }
        return preferences.fantasyLeagueIDs
    }
    var isConfigured: Bool { !leagueIDs.isEmpty }

    var activeLeagueID: String? {
        if let previewLeagueID { return previewLeagueID }
        let id = preferences.activeFantasyLeagueID
        return id.isEmpty ? leagueIDs.first : id
    }

    /// The league the matchup view and the menu bar follow.
    var matchup: FantasyMatchup? {
        activeLeagueID.flatMap { matchups[$0] }
    }

    var state: ConnectionState {
        guard isConfigured else { return .notConfigured }
        guard let activeLeagueID else { return .notConfigured }
        return states[activeLeagueID] ?? .connecting
    }

    /// The active league's chance of winning.
    var winProbability: WinProbability? {
        activeLeagueID.flatMap { winProbabilities[$0] }
    }

    func matchup(for leagueID: String) -> FantasyMatchup? { matchups[leagueID] }
    func state(for leagueID: String) -> ConnectionState { states[leagueID] ?? .connecting }

    func selectLeague(_ leagueID: String) {
        preferences.activeFantasyLeagueID = leagueID
    }

    /// Every matchup, in the order the leagues were added.
    var allMatchups: [(leagueID: String, matchup: FantasyMatchup)] {
        leagueIDs.compactMap { id in matchups[id].map { (id, $0) } }
    }

    /// How many of your starters are in a given NFL game, counted once even if the
    /// same player is on your roster in more than one league.
    func myPlayerCount(inGame game: Game) -> Int {
        Set(players(inGame: game).filter(\.isMine).map(\.player.id)).count
    }

    /// The starters from every connected league who are playing in this game, yours
    /// first. A player rostered in two leagues appears once; being yours wins over
    /// being an opponent's.
    func players(inGame game: Game) -> [(player: RosterPlayer, isMine: Bool)] {
        let teamIDs = [Int(game.home.id), Int(game.away.id)].compactMap { $0 }

        var byPlayer: [Int: (player: RosterPlayer, isMine: Bool)] = [:]
        for (_, matchup) in allMatchups {
            for entry in matchup.allPlayers where entry.player.isStarter {
                guard let proTeamID = entry.player.proTeamID,
                      teamIDs.contains(proTeamID) else { continue }
                if let existing = byPlayer[entry.player.id] {
                    if entry.isMine && !existing.isMine { byPlayer[entry.player.id] = entry }
                } else {
                    byPlayer[entry.player.id] = entry
                }
            }
        }

        return byPlayer.values.sorted { lhs, rhs in
            if lhs.isMine != rhs.isMine { return lhs.isMine }
            return lhs.player.points > rhs.player.points
        }
    }

    /// The same starters, but kept per league rather than pooled — a player you roster
    /// in two leagues genuinely appears twice, because he is scoring for you twice.
    func playersByLeague(inGame game: Game) -> [(leagueID: String, leagueName: String,
                                                 players: [(player: RosterPlayer, isMine: Bool)])] {
        let teamIDs = [Int(game.home.id), Int(game.away.id)].compactMap { $0 }

        return allMatchups.compactMap { entry in
            let players = entry.matchup.allPlayers
                .filter { $0.player.isStarter }
                .filter { player in player.player.proTeamID.map(teamIDs.contains) ?? false }
                .sorted { lhs, rhs in
                    if lhs.isMine != rhs.isMine { return lhs.isMine }
                    return lhs.player.points > rhs.player.points
                }
            guard !players.isEmpty else { return nil }
            return (entry.leagueID, entry.matchup.leagueName, players)
        }
    }

    func credits(forPlay playID: String) -> [PlayAttribution.Credit] {
        creditsByPlay[playID] ?? []
    }

    // MARK: - Lifecycle

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                // Waits in short steps rather than one long sleep, so the interval is
                // looked at again as games start. One five-minute sleep taken before the
                // slate had loaded, or just before a kickoff, left the next poll minutes
                // away while football was being played.
                let finished = Date.now
                while !Task.isCancelled {
                    guard let interval = self?.pollInterval else { return }
                    if Date.now.timeIntervalSince(finished) >= TimeInterval(interval) { break }
                    try? await Task.sleep(for: .seconds(Self.pollStep))
                }
            }
        }
    }

    private static let pollStep = 5

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Fantasy totals only move when football is being played, and plays are scored from
    /// the play feed as it arrives, so the league itself needs no faster polling than this.
    private var pollInterval: Int {
        guard isConfigured else { return 300 }
        guard let games else { return 300 }
        // Until the first scoreboard lands there is no telling whether games are on.
        guard games.lastUpdated != nil else { return 15 }
        return games.liveGames.isEmpty ? 300 : 15
    }

    /// Called after credentials change, to retry immediately rather than waiting.
    func reconnect() {
        CredentialStore.invalidateCache()
        forgetScoring()
        creditsByPlay = [:]
        matchups = [:]
        states = [:]
        winProbabilities = [:]
        Task { await refresh() }
    }

    /// Drops one league, leaving the others connected.
    func remove(leagueID: String) {
        preferences.removeFantasyLeague(leagueID)
        matchups[leagueID] = nil
        states[leagueID] = nil
        winProbabilities[leagueID] = nil
        accuracy[leagueID] = nil
        computedTotals[leagueID] = nil
        ledger.removeLeague(leagueID)
        if leagueIDs.isEmpty {
            games?.trackedGameIDs = []
            creditsByPlay = [:]
        } else {
            rebuildCredits()
            updateTrackedGames()
        }
    }

    // MARK: - Refresh

    func refresh() async {
        guard isConfigured else {
            states = [:]
            matchups = [:]
            winProbabilities = [:]
            return
        }

        let credentials = FantasyClient.Credentials(
            leagueID: "",
            espnS2: CredentialStore.read(.espnS2),
            swid: CredentialStore.read(.swid)
        )

        for leagueID in leagueIDs {
            var forLeague = credentials
            forLeague.leagueID = leagueID
            await refresh(leagueID: leagueID, credentials: forLeague)
        }

        lastUpdated = .now
        updateTrackedGames()
        // The lineups, the starters or the scoring table may have changed, and a feed
        // that arrived before the first matchup did has not been scored at all.
        scoreAllGames()
        updateWinProbabilities()
        checkAgainstESPN(now: .now)
    }

    // MARK: - Checking against ESPN

    /// ESPN's totals trail the play feed by up to a minute or so; a difference that
    /// outlasts this is a real one.
    private static let settleTime: TimeInterval = 180

    /// Points come from scoring each play ourselves, and ESPN's totals are still polled
    /// for the matchup — so each poll is a chance to check one against the other. A
    /// starter whose plays add up to something other than ESPN's figure for longer than
    /// ESPN takes to catch up is logged and listed in the matchup view.
    ///
    /// Team defenses are left out: their points-allowed and yards-allowed tiers belong
    /// to no play, so their plays never add up to their total.
    private func checkAgainstESPN(now: Date) {
        var result: [String: FantasyAccuracy] = [:]
        var stillDisagreeing: [String: Date] = [:]
        for (leagueID, matchup) in allMatchups {
            let computed = computedTotals[leagueID] ?? [:]
            var report = FantasyAccuracy()
            for entry in matchup.allPlayers where entry.player.isStarter && entry.player.position != .defense {
                guard let ours = computed[entry.player.id] else { continue }
                report.checked += 1
                let espn = entry.player.points
                guard abs(ours - espn) >= 0.05 else { continue }
                let key = "\(leagueID)|\(entry.player.id)"
                let since = disagreeingSince[key] ?? now
                stillDisagreeing[key] = since
                guard now.timeIntervalSince(since) >= Self.settleTime else { continue }
                if now.timeIntervalSince(since) < Self.settleTime + 20 {
                    NSLog("[FootballWidget] \(matchup.leagueName): \(entry.player.fullName) plays add up to \(ours), ESPN has \(espn)")
                }
                report.mismatches.append(.init(playerID: entry.player.id, name: entry.player.fullName,
                                               ours: ours, espn: espn))
            }
            result[leagueID] = report
        }
        disagreeingSince = stillDisagreeing
        if result != accuracy { accuracy = result }
    }

    private func refresh(leagueID: String, credentials: FantasyClient.Credentials) async {
        do {
            let fresh = try await client.matchup(credentials: credentials)
            // Only written when changed. Assigning a whole property an equal value is
            // free, but writing through a dictionary subscript notifies every view that
            // reads the dictionary, equal or not — so an unchanged matchup re-ran every
            // game row and the detail view on each poll.
            if matchups[leagueID] != fresh { matchups[leagueID] = fresh }
            if states[leagueID] != .connected { states[leagueID] = .connected }
        } catch {
            let message = (error as? FantasyClient.FantasyError)?.errorDescription
                ?? error.localizedDescription
            if states[leagueID] != .failed(message) { states[leagueID] = .failed(message) }
        }
    }

    /// Ask the NFL store for play-by-play on every game containing a starter on either
    /// side of a matchup, so his plays are scored even in games you are not watching.
    /// A bench player scores for nobody, and tracking his game only cost a feed.
    private func updateTrackedGames() {
        guard let games else { return }
        let teams = Set(allMatchups.flatMap { $0.matchup.allPlayers }
            .filter(\.player.isStarter)
            .compactMap(\.player.proTeamID).map(String.init))
        let ids = games.games
            .filter { teams.contains($0.home.id) || teams.contains($0.away.id) }
            .map(\.id)
        games.trackedGameIDs = Set(ids)
    }

    // MARK: - Win probability

    /// Recomputed on every fantasy poll, which runs every 15 seconds while games are
    /// live. That keeps the arithmetic out of view bodies, and a sub-poll clock tick
    /// would not move ESPN's own number anyway.
    ///
    /// Progress comes from the NFL scoreboard, joined on team id: fantasy `proTeamId`
    /// is the NFL team id.
    private func updateWinProbabilities() {
        var progressByTeam: [Int: GameProgress] = [:]
        for game in games?.games ?? [] {
            guard let progress = GameProgress(game: game) else { continue }
            for teamID in [game.home.id, game.away.id].compactMap({ Int($0) }) {
                progressByTeam[teamID] = progress
            }
        }

        var result: [String: WinProbability] = [:]
        for (leagueID, matchup) in allMatchups {
            result[leagueID] = WinProbability.estimate(for: matchup) { progressByTeam[$0] }
        }
        // Assigning only on change spares the matchup view a redraw on every poll.
        if result != winProbabilities { winProbabilities = result }
    }

    // MARK: - Scoring plays

    /// A play first seen longer ago than this is not news — the league was added
    /// mid-game, or its feed was scored late — so it gets its chip but no alert.
    private static let alertableAge: TimeInterval = 150

    private func feedUpdated(gameID: String, detail: GameDetail) {
        guard !allMatchups.isEmpty else { return }
        score(gameID: gameID, detail: detail, now: .now)
        rebuildCredits()
    }

    /// Scores every game whose feed is in hand, and forgets games gone from the slate.
    private func scoreAllGames() {
        guard let games else { return }
        let now = Date.now
        for game in games.games {
            guard let detail = games.detail(id: game.id) else { continue }
            score(gameID: game.id, detail: detail, now: now)
        }
        let onSlate = Set(games.games.map(\.id))
        ledger.retainGames(onSlate)
        summaries = summaries.filter { onSlate.contains($0.key) }
        scored = scored.filter { onSlate.contains($0.key) }
        judged = judged.filter { onSlate.contains($0.key) }
        awaitingRuling = awaitingRuling.filter { onSlate.contains($0.key) }
        rebuildCredits()
    }

    /// Scores one game's plays for every starter in it, in every league, and sends the
    /// plays new enough to be news to the alert engine.
    ///
    /// Plays that were already in the feed the first time it arrived happened before
    /// anyone was watching: they get chips, back-filled for the whole game, but never
    /// an alert. A play under review waits for the ruling.
    private func score(gameID: String, detail: GameDetail, now: Date) {
        guard let games, let game = games.game(id: gameID) else { return }
        let teams = Set([game.home.id, game.away.id])
        let leagues = allMatchups.map { entry in
            (entry.leagueID, entry.matchup, entry.matchup.allPlayers.filter { candidate in
                candidate.player.isStarter
                    && candidate.player.proTeamID.map { teams.contains(String($0)) } == true
            })
        }
        guard leagues.contains(where: { !$0.2.isEmpty }) else {
            for (leagueID, _, _) in leagues { ledger.replace(game: gameID, league: leagueID, with: [:]) }
            return
        }

        var feed: ScoredFeed
        if let cached = scored[gameID], cached.detail == detail {
            feed = cached
        } else {
            var cache = summaries[gameID] ?? [:]
            let scorer = FantasyGameScorer(detail: detail, game: game) { play in
                if let known = cache[play.id], known.text == play.text { return known.summary }
                let summary = PlaySummary.parse(play.text)
                cache[play.id] = (play.text, summary)
                return summary
            }
            summaries[gameID] = cache
            feed = ScoredFeed(detail: detail, scorer: scorer)
        }
        defer { scored[gameID] = feed }

        var judgedHere = judged[gameID] ?? []
        var heldHere = awaitingRuling[gameID] ?? [:]
        for (leagueID, matchup, players) in leagues {
            var plays: [String: [Int: Double]] = [:]
            var moments: [FantasyMoment] = []
            for entry in players {
                var gameTotal = 0.0
                defer {
                    computedTotals[leagueID, default: [:]][entry.player.id] = (gameTotal * 100).rounded() / 100
                }
                let lines = feed.lines[entry.player.id] ?? feed.scorer.lines(for: entry.player)
                feed.lines[entry.player.id] = lines
                for line in lines {
                    let points = matchup.scoringRules.points(for: line.stats, position: entry.player.position)
                    gameTotal += points
                    if points != 0 { plays[line.play.id, default: [:]][entry.player.id] = points }

                    let key = "\(leagueID)|\(entry.player.id)|\(line.play.id)"
                    if line.isUnderReview {
                        heldHere[key] = now
                        continue
                    }
                    guard judgedHere.insert(key).inserted else { continue }
                    let reviewed = heldHere.removeValue(forKey: key)
                    guard points > 0,
                          isNews(line.play.id, gameID: gameID, reviewedAt: reviewed, now: now)
                    else { continue }

                    // ESPN's total for him trails the feed; what the plays add up to so far
                    // is the better figure until it catches up. Not for a team defense: its
                    // points-allowed and yards-allowed tiers belong to no play, so its plays
                    // never add up to its total (checked live: off by −6 to +1).
                    var player = entry.player
                    if player.position != .defense {
                        player.points = max(player.points, (gameTotal * 100).rounded() / 100)
                    }
                    moments.append(FantasyMoment(
                        player: player, isMine: entry.isMine, delta: points,
                        playText: line.play.text, isTouchdown: line.stats.isTouchdown,
                        playID: line.play.id, pointsOnPlay: points
                    ))
                }
            }
            ledger.replace(game: gameID, league: leagueID, with: plays)

            guard !moments.isEmpty else { continue }
            let settings = preferences.fantasyAlertSettings
            // Only worth naming the league when there is more than one.
            let leagueName = leagueIDs.count > 1 ? matchup.leagueName : nil
            Task { [alerts, moments] in
                await alerts.processFantasy(moments: moments, matchup: matchup, settings: settings,
                                            leagueName: leagueName, leagueID: leagueID)
            }
        }
        judged[gameID] = judgedHere
        awaitingRuling[gameID] = heldHere
    }

    /// Whether a play is new enough to interrupt for. `reviewedAt` is when it was last
    /// seen under review: the ruling is the news, however long the review took.
    private func isNews(_ playID: String, gameID: String, reviewedAt: Date?, now: Date) -> Bool {
        guard let seen = games?.firstSeen(playID: playID, inGame: gameID), seen != .distantPast
        else { return false }
        let since = reviewedAt.map { max($0, seen) } ?? seen
        return now.timeIntervalSince(since) <= Self.alertableAge
    }

    /// Turns the ledger into the chips the field map draws.
    ///
    /// Starters only, pooled across leagues and deduplicated by player. A bench player
    /// scores nothing for either side. The league a player is pooled from — yours over an
    /// opponent's — is the one his chip reads its points from. Each play's chips are
    /// yours first, then the biggest, since a row only has room for two.
    private func rebuildCredits() {
        guard let games else { return }
        var pooled: [Int: (player: RosterPlayer, isMine: Bool, leagueID: String)] = [:]
        for (leagueID, matchup) in allMatchups {
            for entry in matchup.allPlayers where entry.player.isStarter {
                if let existing = pooled[entry.player.id], existing.isMine || !entry.isMine { continue }
                pooled[entry.player.id] = (entry.player, entry.isMine, leagueID)
            }
        }

        var gameByTeam: [String: String] = [:]
        for game in games.games {
            gameByTeam[game.home.id] = game.id
            gameByTeam[game.away.id] = game.id
        }

        var result: [String: [PlayAttribution.Credit]] = [:]
        for entry in pooled.values {
            guard let team = entry.player.proTeamID, let gameID = gameByTeam[String(team)] else { continue }
            for (playID, byPlayer) in ledger.plays(league: entry.leagueID, game: gameID) {
                guard let points = byPlayer[entry.player.id], abs(points) >= 0.05 else { continue }
                result[playID, default: []].append(PlayAttribution.Credit(
                    playerID: entry.player.id, playerName: entry.player.fullName,
                    isMine: entry.isMine, position: entry.player.position, points: points
                ))
            }
        }
        for (playID, credits) in result {
            result[playID] = credits.sorted { lhs, rhs in
                if lhs.isMine != rhs.isMine { return lhs.isMine }
                let left = abs(lhs.points ?? 0), right = abs(rhs.points ?? 0)
                return left != right ? left > right : lhs.playerID < rhs.playerID
            }
        }
        if result != creditsByPlay { creditsByPlay = result }
    }

    private func forgetScoring() {
        ledger = FantasyLedger()
        summaries = [:]
        scored = [:]
        judged = [:]
        awaitingRuling = [:]
        computedTotals = [:]
        disagreeingSince = [:]
        accuracy = [:]
    }

    /// Forgets every league and the stored cookies.
    func disconnect() {
        CredentialStore.delete(.espnS2)
        CredentialStore.delete(.swid)
        for id in leagueIDs { preferences.removeFantasyLeague(id) }
        matchups = [:]
        states = [:]
        forgetScoring()
        creditsByPlay = [:]
        winProbabilities = [:]
        games?.trackedGameIDs = []
    }
}

/// How one league's play-by-play points compare with ESPN's totals.
struct FantasyAccuracy: Equatable {
    struct Mismatch: Equatable, Identifiable {
        var playerID: Int
        var name: String
        var ours: Double
        var espn: Double
        var id: Int { playerID }
    }

    /// Starters whose game has been scored, defenses aside.
    var checked = 0
    /// Those still off from ESPN after it has had time to catch up.
    var mismatches: [Mismatch] = []
}
