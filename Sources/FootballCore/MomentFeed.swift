import Foundation

/// One line in RedZone's whip-around: something that just happened in some game.
public struct Moment: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case scoring, turnover, redZone, final }

    /// "\(gameID)|\(alertEvent.id)", or "\(gameID)|final".
    public var id: String
    public var gameID: String
    public var kind: Kind
    /// The alert's title, or "Final · KC 27–24 BUF".
    public var title: String
    public var detail: String?
    /// Scoring: the team whose score rose. Turnover and red zone: the team with the ball
    /// afterwards. Final: the winner.
    public var teamID: String?
    /// The game clock when it happened — "Q3 4:12", "HALF", "FINAL" — so a row never needs
    /// a wall-clock "2m ago" that has to keep redrawing.
    public var clock: String
    public var at: Date

    public init(id: String, gameID: String, kind: Kind, title: String, detail: String?,
                teamID: String?, clock: String, at: Date) {
        self.id = id
        self.gameID = gameID
        self.kind = kind
        self.title = title
        self.detail = detail
        self.teamID = teamID
        self.clock = clock
        self.at = at
    }
}

/// Key moments from every game, newest first.
///
/// It runs the same rules as the banners but keeps its own snapshots and always uses
/// default settings, so the feed is complete whatever the user has chosen to be
/// interrupted for — and turning RedZone on or off never changes which banners fire.
public struct MomentFeed: Sendable {

    public static let capacity = 30
    /// Same reasoning as the banners: after a longer gap the snapshots describe the game
    /// as it was minutes ago, and a quarter of football would arrive as one moment.
    public static let maximumGap: TimeInterval = 150

    public private(set) var moments: [Moment]

    private var snapshots: [String: GameSnapshot] = [:]
    private var phases: [String: GamePhase] = [:]
    private var lastSeen: Date?

    public init() {
        moments = []
    }

    /// The newest scoring or turnover moment for that game — the ranker's "just happened".
    public func latest(gameID: String) -> Moment? {
        moments.first { $0.gameID == gameID && ($0.kind == .scoring || $0.kind == .turnover) }
    }

    /// Compares this poll against the last one. Returns whether `moments` changed.
    ///
    /// A game seen for the first time is silent, like the banners: otherwise every game
    /// already in progress would flood the feed at launch.
    @discardableResult
    public mutating func ingest(_ games: [Game], now: Date) -> Bool {
        if let lastSeen, now.timeIntervalSince(lastSeen) > Self.maximumGap {
            snapshots = [:]
            phases = [:]
        }
        lastSeen = now

        var fresh: [Moment] = []
        for game in games {
            let previous = snapshots[game.id]
            for event in AlertRules.events(previous: previous, game: game, settings: AlertSettings()) {
                guard let kind = Self.kind(event.kind), let previous else { continue }
                fresh.append(Moment(
                    id: "\(game.id)|\(event.id)",
                    gameID: game.id,
                    kind: kind,
                    title: event.title,
                    detail: Self.detail(event),
                    teamID: Self.teamID(kind, previous: previous, game: game),
                    clock: RedZoneText.clock(game) ?? "",
                    at: now
                ))
            }
            if phases[game.id]?.isLive == true, game.phase == .final {
                fresh.append(Moment(
                    id: "\(game.id)|final",
                    gameID: game.id,
                    kind: .final,
                    title: "Final · \(AlertRules.scoreLine(game))",
                    detail: nil,
                    teamID: Self.winner(game)?.id,
                    clock: RedZoneText.clock(game) ?? "FINAL",
                    at: now
                ))
            }
            snapshots[game.id] = GameSnapshot(game: game, previous: previous)
            phases[game.id] = game.phase
        }

        // Forget games that have dropped off the slate; their moments stay in the feed.
        let ids = Set(games.map(\.id))
        snapshots = snapshots.filter { ids.contains($0.key) }
        phases = phases.filter { ids.contains($0.key) }

        var known = Set(moments.map(\.id))
        let added = fresh.filter { known.insert($0.id).inserted }
        guard !added.isEmpty else { return false }
        moments = Array((added + moments).prefix(Self.capacity))
        return true
    }

    /// A poll that came back identical to the last one still counts as having looked: a
    /// halftime with nothing changing must not read as a gap.
    public mutating func scoreboardUnchanged(now: Date) {
        lastSeen = now
    }

    // MARK: - Mapping

    private static func kind(_ kind: AlertKind) -> Moment.Kind? {
        switch kind {
        case .scoring: return .scoring
        case .turnover: return .turnover
        case .redZone: return .redZone
        case .fantasy: return nil
        }
    }

    private static func detail(_ event: AlertEvent) -> String? {
        if let subtitle = event.subtitle, !subtitle.isEmpty { return subtitle }
        return event.body.isEmpty ? nil : event.body
    }

    private static func teamID(_ kind: Moment.Kind, previous: GameSnapshot, game: Game) -> String? {
        switch kind {
        case .scoring:
            let home = game.home.score > previous.homeScore
            let away = game.away.score > previous.awayScore
            // Both moving between polls means polls were missed; it is nobody's moment.
            if home == away { return nil }
            return home ? game.home.id : game.away.id
        case .turnover, .redZone:
            return game.teamWithPossession?.id
        case .final:
            return winner(game)?.id
        }
    }

    private static func winner(_ game: Game) -> TeamSide? {
        if game.home.isWinner { return game.home }
        if game.away.isWinner { return game.away }
        if game.home.score == game.away.score { return nil }
        return game.home.score > game.away.score ? game.home : game.away
    }
}
