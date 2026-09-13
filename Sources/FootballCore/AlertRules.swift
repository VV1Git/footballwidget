import Foundation

/// Deciding *whether* to alert is separate from delivering one, so the rules can be
/// tested without posting notifications to anybody's screen.

public struct GameSnapshot: Sendable, Equatable {
    public var homeScore: Int
    public var awayScore: Int
    public var isRedZone: Bool
    public var possessionTeamID: String?
    public var lastPlayID: String?

    public init(homeScore: Int, awayScore: Int, isRedZone: Bool,
                possessionTeamID: String?, lastPlayID: String?) {
        self.homeScore = homeScore
        self.awayScore = awayScore
        self.isRedZone = isRedZone
        self.possessionTeamID = possessionTeamID
        self.lastPlayID = lastPlayID
    }

    public init(game: Game) {
        self.init(
            homeScore: game.home.score,
            awayScore: game.away.score,
            isRedZone: game.situation?.isRedZone ?? false,
            possessionTeamID: game.situation?.possessionTeamID,
            lastPlayID: game.situation?.lastPlayID
        )
    }
}

public enum AlertKind: String, Sendable, Equatable {
    case scoring, turnover, redZone, fantasy
}

public struct AlertEvent: Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: AlertKind
    public var title: String
    public var body: String
    public var subtitle: String?

    public init(id: String, kind: AlertKind, title: String, body: String, subtitle: String?) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.subtitle = subtitle
    }
}

public struct AlertSettings: Sendable {
    public var enabled: Bool
    public var favoritesOnly: Bool
    public var favorites: Set<String>
    public var scoring: Bool
    public var turnovers: Bool
    public var redZone: Bool

    public init(enabled: Bool = true, favoritesOnly: Bool = false,
                favorites: Set<String> = [], scoring: Bool = true,
                turnovers: Bool = true, redZone: Bool = true) {
        self.enabled = enabled
        self.favoritesOnly = favoritesOnly
        self.favorites = favorites
        self.scoring = scoring
        self.turnovers = turnovers
        self.redZone = redZone
    }
}

public enum AlertRules {

    /// What should fire for one game, given how it looked last time we looked.
    ///
    /// `previous == nil` means this is the first time the game has been seen, and
    /// nothing fires — otherwise every game in progress would alert at launch.
    public static func events(
        previous: GameSnapshot?,
        game: Game,
        settings: AlertSettings
    ) -> [AlertEvent] {
        guard settings.enabled, game.isLive, let previous else { return [] }
        guard !settings.favoritesOnly || isFavorite(game, settings.favorites) else { return [] }

        var events: [AlertEvent] = []
        if settings.scoring, let event = scoringEvent(previous: previous, game: game) {
            events.append(event)
        }
        if settings.turnovers, let event = turnoverEvent(previous: previous, game: game) {
            events.append(event)
        }
        if settings.redZone, let event = redZoneEvent(previous: previous, game: game) {
            events.append(event)
        }
        return events
    }

    public static func isFavorite(_ game: Game, _ favorites: Set<String>) -> Bool {
        favorites.contains(game.home.abbreviation) || favorites.contains(game.away.abbreviation)
    }

    // MARK: - Rules

    /// Derived from the score changing rather than from `scoringPlays`, so it works
    /// for every game on the slate — the play feed is only fetched for one at a time.
    static func scoringEvent(previous: GameSnapshot, game: Game) -> AlertEvent? {
        let homeDelta = game.home.score - previous.homeScore
        let awayDelta = game.away.score - previous.awayScore
        guard homeDelta > 0 || awayDelta > 0 else { return nil }

        let scorer = homeDelta >= awayDelta ? game.home : game.away
        let points = max(homeDelta, awayDelta)
        let kind: String
        switch points {
        case 6, 7, 8: kind = "Touchdown"
        case 3: kind = "Field goal"
        case 2: kind = "Safety"
        case 1: kind = "Extra point"
        default: kind = "Score"
        }

        return AlertEvent(
            id: "score-\(game.id)-\(game.home.score)-\(game.away.score)",
            kind: .scoring,
            title: "\(kind) — \(scorer.abbreviation)",
            body: scoreLine(game),
            subtitle: game.situation?.lastPlayText
        )
    }

    static func turnoverEvent(previous: GameSnapshot, game: Game) -> AlertEvent? {
        guard let situation = game.situation,
              situation.lastPlayWasTurnover,
              let playID = situation.lastPlayID,
              playID != previous.lastPlayID
        else { return nil }

        return AlertEvent(
            id: "turnover-\(playID)",
            kind: .turnover,
            title: "Turnover — \(game.shortName)",
            body: situation.lastPlayText ?? scoreLine(game),
            subtitle: scoreLine(game)
        )
    }

    /// Fires once on entering the red zone, not on every snap inside the 20 — so it
    /// is suppressed while the same team stays there, and re-arms on a change of
    /// possession.
    static func redZoneEvent(previous: GameSnapshot, game: Game) -> AlertEvent? {
        guard let situation = game.situation, situation.isRedZone else { return nil }
        let possessionChanged = situation.possessionTeamID != previous.possessionTeamID
        guard !previous.isRedZone || possessionChanged else { return nil }

        let team = game.teamWithPossession
        return AlertEvent(
            id: "redzone-\(game.id)-\(situation.possessionTeamID ?? "?")-\(game.home.score)-\(game.away.score)",
            kind: .redZone,
            title: "Red zone — \(team?.abbreviation ?? game.shortName)",
            body: scoreLine(game),
            subtitle: situation.downDistanceText
        )
    }

    static func scoreLine(_ game: Game) -> String {
        "\(game.away.abbreviation) \(game.away.score)–\(game.home.abbreviation) \(game.home.score) · \(game.liveSummary)"
    }
}
