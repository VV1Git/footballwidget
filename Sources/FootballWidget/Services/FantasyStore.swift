import Foundation
import Observation
import FootballCore

/// Owns your fantasy matchup: polls the league, works out what changed, ties changes to
/// the plays that caused them, and hands the results to the views and the alert engine.
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

    private let client: FantasyClient
    private let preferences: Preferences
    private let alerts: AlertEngine
    private weak var games: GameStore?

    /// Last seen points per player, per league, for diffing.
    private var previousPoints: [String: [Int: Double]] = [:]
    /// Points banked against the play that earned them: play id → player id → points.
    /// Accumulated as deltas arrive, because ESPN never reports points per play.
    /// Restored from disk so a relaunch does not wipe every chip off the field map.
    private var pointsByPlay: [String: [Int: Double]] = PlayPointsStore.load()
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
                let seconds = self?.pollInterval ?? 60
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Fantasy totals only move when football is being played, and they lag the play
    /// feed by a few seconds anyway, so there is no point polling faster than this.
    private var pollInterval: Int {
        guard isConfigured else { return 300 }
        guard let games, !games.liveGames.isEmpty else { return 300 }
        return 15
    }

    /// Called after credentials change, to retry immediately rather than waiting.
    func reconnect() {
        CredentialStore.invalidateCache()
        previousPoints = [:]
        pointsByPlay = [:]
        PlayPointsStore.clear()
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
        previousPoints[leagueID] = nil
        winProbabilities[leagueID] = nil
        if leagueIDs.isEmpty {
            games?.trackedGameIDs = []
            creditsByPlay = [:]
            pointsByPlay = [:]
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
        rebuildCredits()
        updateWinProbabilities()
    }

    private func refresh(leagueID: String, credentials: FantasyClient.Credentials) async {
        do {
            let fresh = try await client.matchup(credentials: credentials)
            let current = PlayAttribution.pointsByPlayer(fresh)
            let deltas = PlayAttribution.deltas(
                previous: previousPoints[leagueID] ?? [:], current: current
            )

            // Only written when changed. Assigning a whole property an equal value is
            // free, but writing through a dictionary subscript notifies every view that
            // reads the dictionary, equal or not — so an unchanged matchup re-ran every
            // game row and the detail view on each poll.
            if matchups[leagueID] != fresh { matchups[leagueID] = fresh }
            previousPoints[leagueID] = current
            if states[leagueID] != .connected { states[leagueID] = .connected }

            let moments = attribute(deltas: deltas, matchup: fresh)
            if !moments.isEmpty {
                await alerts.processFantasy(
                    moments: moments,
                    matchup: fresh,
                    settings: preferences.fantasyAlertSettings,
                    // Only worth naming the league when there is more than one.
                    leagueName: leagueIDs.count > 1 ? fresh.leagueName : nil
                )
            }
        } catch {
            let message = (error as? FantasyClient.FantasyError)?.errorDescription
                ?? error.localizedDescription
            if states[leagueID] != .failed(message) { states[leagueID] = .failed(message) }
        }
    }

    /// Ask the NFL store for play-by-play on every game containing someone in the
    /// matchup, so alerts can quote the play even for games you are not watching.
    private func updateTrackedGames() {
        guard let games else { return }
        let teams = Set(allMatchups.flatMap { $0.matchup.allPlayers }
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

    // MARK: - Attribution

    /// Ties each point change to the play that most likely caused it.
    private func attribute(deltas: [Int: Double], matchup: FantasyMatchup) -> [FantasyMoment] {
        guard !deltas.isEmpty else { return [] }

        var moments: [FantasyMoment] = []
        var banked = false
        for entry in matchup.allPlayers {
            guard let delta = deltas[entry.player.id] else { continue }
            // Bench points are banked for nobody: they neither alert nor chip.
            guard entry.player.isStarter else { continue }

            let play = playFor(player: entry.player)
            // Bank the points against the play so the field map can show what that
            // play was worth, now and for the rest of the game.
            if let play {
                var forPlay = pointsByPlay[play.id] ?? [:]
                forPlay[entry.player.id] = (forPlay[entry.player.id] ?? 0) + delta
                pointsByPlay[play.id] = forPlay
                banked = true
            }
            moments.append(FantasyMoment(
                player: entry.player,
                isMine: entry.isMine,
                delta: delta,
                playText: play?.text,
                // A big jump with no identifiable play is still almost certainly a
                // score — a defensive or special teams touchdown, typically. Otherwise
                // only a touchdown counts: a field goal is a scoring play too, and a
                // kicker's extra point is written into the touchdown's play text.
                isTouchdown: play.map {
                    $0.scoreKind == .touchdown && entry.player.position != .kicker
                } ?? (delta >= 6)
            ))
        }
        if banked { PlayPointsStore.save(pointsByPlay) }
        return moments
    }

    private func playFor(player: RosterPlayer) -> Play? {
        guard let games, let proTeamID = player.proTeamID else { return nil }
        let team = String(proTeamID)
        guard let game = games.games.first(where: { $0.home.id == team || $0.away.id == team }),
              let detail = games.detail(id: game.id)
        else { return nil }
        return PlayAttribution.mostRecentPlay(naming: player, in: detail)
    }

    /// Recomputes which plays name which rostered players, for the field map chips.
    ///
    /// Only plays with banked points produce a chip. Naming alone is not interesting —
    /// the quarterback is named on every dropback, which would put a chip on almost
    /// every row and drown out the plays that actually scored.
    ///
    /// The corollary is that plays which happened before the widget started have no
    /// chip: ESPN reports running totals, not per-play points, so there is nothing to
    /// back-fill from.
    private func rebuildCredits() {
        guard let games else { return }
        var result: [String: [PlayAttribution.Credit]] = [:]

        // Starters only, pooled across leagues and deduplicated by player. A bench
        // player scores nothing for either side, and benching a quarterback — who is
        // named in every single dropback — would put a chip on most of the drive.
        var pooled: [Int: (player: RosterPlayer, isMine: Bool)] = [:]
        for (_, matchup) in allMatchups {
            for entry in matchup.allPlayers where entry.player.isStarter {
                if let existing = pooled[entry.player.id] {
                    if entry.isMine && !existing.isMine { pooled[entry.player.id] = entry }
                } else {
                    pooled[entry.player.id] = entry
                }
            }
        }
        let everyone = Array(pooled.values)

        for game in games.games {
            guard let detail = games.detail(id: game.id) else { continue }
            let teamIDs = [game.home.id, game.away.id]
            let candidates = everyone.filter { entry in
                guard let proTeamID = entry.player.proTeamID else { return false }
                return teamIDs.contains(String(proTeamID))
            }
            guard !candidates.isEmpty else { continue }

            for drive in detail.drives {
                for play in drive.plays where play.kind != .administrative {
                    guard let banked = pointsByPlay[play.id], !banked.isEmpty else { continue }
                    // Points banked against an incompletion were pinned there by mistake
                    // (an older build did that); a chip on one would be wrong.
                    guard PlayAttribution.canScore(playText: play.text) else { continue }
                    let credits = PlayAttribution.credits(
                        forPlayText: play.text,
                        candidates: candidates,
                        deltas: banked
                    )
                    .filter { $0.points != nil }
                    if !credits.isEmpty { result[play.id] = credits }
                }
            }
        }
        creditsByPlay = result
    }

    /// Forgets every league and the stored cookies.
    func disconnect() {
        CredentialStore.delete(.espnS2)
        CredentialStore.delete(.swid)
        for id in leagueIDs { preferences.removeFantasyLeague(id) }
        matchups = [:]
        states = [:]
        previousPoints = [:]
        pointsByPlay = [:]
        PlayPointsStore.clear()
        creditsByPlay = [:]
        winProbabilities = [:]
        games?.trackedGameIDs = []
    }
}
