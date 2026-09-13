import Foundation

// MARK: - Status

public enum GamePhase: String, Sendable, Hashable {
    case pre, live, halftime, final, unknown

    public var isLive: Bool { self == .live || self == .halftime }
}

// MARK: - Teams

public struct TeamSide: Identifiable, Hashable, Sendable {
    public var id: String
    public var abbreviation: String
    public var displayName: String
    public var shortName: String
    public var score: Int
    public var record: String?
    /// ESPN ships colors as bare hex without a leading `#`.
    public var primaryHex: String?
    public var secondaryHex: String?
    public var logoURL: URL?
    public var isWinner: Bool
    public var timeoutsLeft: Int?

    public init(
        id: String, abbreviation: String, displayName: String, shortName: String,
        score: Int, record: String? = nil, primaryHex: String? = nil,
        secondaryHex: String? = nil, logoURL: URL? = nil, isWinner: Bool = false,
        timeoutsLeft: Int? = nil
    ) {
        self.id = id
        self.abbreviation = abbreviation
        self.displayName = displayName
        self.shortName = shortName
        self.score = score
        self.record = record
        self.primaryHex = primaryHex
        self.secondaryHex = secondaryHex
        self.logoURL = logoURL
        self.isWinner = isWinner
        self.timeoutsLeft = timeoutsLeft
    }
}

// MARK: - Live situation

public struct Situation: Hashable, Sendable {
    public var possessionTeamID: String?
    /// "3rd & 4"
    public var shortDownDistance: String?
    /// "3rd & 4 at KC 45"
    public var downDistanceText: String?
    /// "KC 45" — where the ball is spotted.
    public var possessionText: String?
    public var yardLine: Int?
    public var down: Int?
    public var distance: Int?
    public var isRedZone: Bool
    public var homeTimeouts: Int?
    public var awayTimeouts: Int?
    public var lastPlayText: String?
    public var lastPlayID: String?
    public var lastPlayTypeID: String?
    public var lastPlayWasScoring: Bool
    public var lastPlayWasTurnover: Bool

    public init(
        possessionTeamID: String? = nil, shortDownDistance: String? = nil,
        downDistanceText: String? = nil, possessionText: String? = nil,
        yardLine: Int? = nil, down: Int? = nil, distance: Int? = nil,
        isRedZone: Bool = false, homeTimeouts: Int? = nil, awayTimeouts: Int? = nil,
        lastPlayText: String? = nil, lastPlayID: String? = nil,
        lastPlayTypeID: String? = nil, lastPlayWasScoring: Bool = false,
        lastPlayWasTurnover: Bool = false
    ) {
        self.possessionTeamID = possessionTeamID
        self.shortDownDistance = shortDownDistance
        self.downDistanceText = downDistanceText
        self.possessionText = possessionText
        self.yardLine = yardLine
        self.down = down
        self.distance = distance
        self.isRedZone = isRedZone
        self.homeTimeouts = homeTimeouts
        self.awayTimeouts = awayTimeouts
        self.lastPlayText = lastPlayText
        self.lastPlayID = lastPlayID
        self.lastPlayTypeID = lastPlayTypeID
        self.lastPlayWasScoring = lastPlayWasScoring
        self.lastPlayWasTurnover = lastPlayWasTurnover
    }
}

// MARK: - Game

public struct Game: Identifiable, Hashable, Sendable {
    public var id: String
    public var shortName: String
    public var kickoff: Date?
    public var phase: GamePhase
    /// "Final", "9/10 - 8:35 PM EDT", "Halftime"
    public var statusDetail: String
    public var period: Int
    public var displayClock: String
    public var home: TeamSide
    public var away: TeamSide
    public var situation: Situation?
    public var broadcast: String?
    public var venue: String?

    public init(
        id: String, shortName: String, kickoff: Date? = nil, phase: GamePhase,
        statusDetail: String, period: Int, displayClock: String,
        home: TeamSide, away: TeamSide, situation: Situation? = nil,
        broadcast: String? = nil, venue: String? = nil
    ) {
        self.id = id
        self.shortName = shortName
        self.kickoff = kickoff
        self.phase = phase
        self.statusDetail = statusDetail
        self.period = period
        self.displayClock = displayClock
        self.home = home
        self.away = away
        self.situation = situation
        self.broadcast = broadcast
        self.venue = venue
    }

    public var isLive: Bool { phase.isLive }

    public var teamWithPossession: TeamSide? {
        guard let pid = situation?.possessionTeamID else { return nil }
        if pid == home.id { return home }
        if pid == away.id { return away }
        return nil
    }

    public func team(id: String?) -> TeamSide? {
        guard let id else { return nil }
        if id == home.id { return home }
        if id == away.id { return away }
        return nil
    }

    /// "Q3", "OT", "HALF" — short enough for a compact row.
    public var periodLabel: String {
        switch phase {
        case .final: return period > 4 ? "FINAL/OT" : "FINAL"
        case .halftime: return "HALF"
        case .pre: return ""
        default: break
        }
        if period <= 0 { return "" }
        if period <= 4 { return "Q\(period)" }
        return period == 5 ? "OT" : "\(period - 4)OT"
    }

    /// One-line live summary: "Q3 2:14 · 3rd & 4 at KC 45"
    public var liveSummary: String {
        var parts: [String] = []
        let p = periodLabel
        if !p.isEmpty { parts.append(displayClock.isEmpty ? p : "\(p) \(displayClock)") }
        if let dd = situation?.downDistanceText, !dd.isEmpty { parts.append(dd) }
        return parts.joined(separator: " · ")
    }

    public var scoreMargin: Int { abs(home.score - away.score) }
}

// MARK: - Plays and drives

public enum PlayKind: String, Sendable, Hashable {
    /// Timeouts, two-minute warning, end of period. Never a snap; excluded from the field map.
    case administrative
    /// Frame starts with the kicking team. Rendered as the drive's starting spot.
    case kickoff
    /// Punt or turnover return — ball changes hands mid-play, so the end frame flips.
    case changeOfPossession
    /// A normal play from scrimmage.
    case scrimmage
}

public struct PlayNode: Hashable, Sendable {
    public var teamID: String?
    /// Distance to the end zone *the team named in `teamID` is attacking*.
    public var yardsToEndzone: Int?
    public var yardLine: Int?
    public var down: Int?
    public var distance: Int?

    public init(teamID: String? = nil, yardsToEndzone: Int? = nil, yardLine: Int? = nil,
                down: Int? = nil, distance: Int? = nil) {
        self.teamID = teamID
        self.yardsToEndzone = yardsToEndzone
        self.yardLine = yardLine
        self.down = down
        self.distance = distance
    }
}

public struct Play: Identifiable, Hashable, Sendable {
    public var id: String
    public var sequence: Int
    public var typeID: String?
    public var typeText: String
    public var text: String
    public var downDistanceText: String?
    public var yards: Int
    public var period: Int
    public var clock: String
    public var isScoring: Bool
    public var isTurnover: Bool
    public var isPenalty: Bool
    /// Running score after this play, as reported by the play feed.
    public var homeScore: Int?
    public var awayScore: Int?
    public var start: PlayNode
    public var end: PlayNode
    public var kind: PlayKind

    public init(
        id: String, sequence: Int, typeID: String?, typeText: String, text: String,
        downDistanceText: String?, yards: Int, period: Int, clock: String,
        isScoring: Bool, isTurnover: Bool, isPenalty: Bool,
        homeScore: Int? = nil, awayScore: Int? = nil,
        start: PlayNode, end: PlayNode, kind: PlayKind
    ) {
        self.id = id
        self.sequence = sequence
        self.typeID = typeID
        self.typeText = typeText
        self.text = text
        self.downDistanceText = downDistanceText
        self.yards = yards
        self.period = period
        self.clock = clock
        self.isScoring = isScoring
        self.isTurnover = isTurnover
        self.isPenalty = isPenalty
        self.homeScore = homeScore
        self.awayScore = awayScore
        self.start = start
        self.end = end
        self.kind = kind
    }

    /// "+12", "-3", "0" — the compact yardage chip.
    public var yardageLabel: String {
        yards > 0 ? "+\(yards)" : "\(yards)"
    }
}

public struct Drive: Identifiable, Hashable, Sendable {
    public var id: String
    public var teamID: String?
    public var teamAbbreviation: String
    /// "Touchdown", "Punt", "Interception"
    public var result: String
    public var isScore: Bool
    public var yards: Int
    public var playCount: Int
    public var timeElapsed: String
    /// "12 plays, 75 yards, 6:41"
    public var summary: String
    public var startText: String?
    /// Where the drive finished, e.g. "Punt" or "LAR 41" — ESPN's own wording.
    public var endText: String?
    public var plays: [Play]
    public var isCurrent: Bool

    /// How the drive ended, in the plainest words available: "Touchdown", "Punt",
    /// "Turnover on downs". Nil while it is still going.
    public var outcome: String? {
        guard !isCurrent else { return nil }
        let text = result.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text != "—" else { return nil }
        // ESPN says "Downs" for a failed fourth down, which reads like a column header.
        if text.caseInsensitiveCompare("Downs") == .orderedSame { return "Turnover on downs" }
        return text
    }

    /// Whether the drive ended by losing the ball rather than scoring or punting.
    public var endedInTurnover: Bool {
        guard let outcome = outcome?.lowercased() else { return false }
        return outcome.contains("interception") || outcome.contains("fumble")
            || outcome.contains("downs")
    }

    public init(
        id: String, teamID: String?, teamAbbreviation: String, result: String,
        isScore: Bool, yards: Int, playCount: Int, timeElapsed: String,
        summary: String, startText: String?, endText: String? = nil,
        plays: [Play], isCurrent: Bool
    ) {
        self.id = id
        self.teamID = teamID
        self.teamAbbreviation = teamAbbreviation
        self.result = result
        self.isScore = isScore
        self.yards = yards
        self.playCount = playCount
        self.timeElapsed = timeElapsed
        self.summary = summary
        self.startText = startText
        self.endText = endText
        self.plays = plays
        self.isCurrent = isCurrent
    }
}

/// Everything the detail view needs for one game beyond its scoreboard row.
public struct GameDetail: Sendable, Hashable {
    public var gameID: String
    public var drives: [Drive]
    public var scoringPlayIDs: [String]

    public init(gameID: String, drives: [Drive], scoringPlayIDs: [String]) {
        self.gameID = gameID
        self.drives = drives
        self.scoringPlayIDs = scoringPlayIDs
    }

    /// Newest drive first — the live one if there is one.
    public var mostRecentDrive: Drive? { drives.first }
}
