import Foundation

/// Fantasy lineup slots. Bench and IR do not count toward your score, which is the only
/// distinction the widget needs to make.
public enum LineupSlot: Sendable, Hashable {
    case starting(String)
    case bench
    case injuredReserve

    public var isStarter: Bool {
        if case .starting = self { return true }
        return false
    }

    public var label: String {
        switch self {
        case .starting(let name): return name
        case .bench: return "BE"
        case .injuredReserve: return "IR"
        }
    }

    /// Lineup order as it appears on ESPN: quarterback first, kicker and defense last.
    /// Used so two lineups can be shown side by side and mostly line up by position.
    public var sortOrder: Int {
        switch self {
        case .starting(let name):
            switch name {
            case "QB", "TQB": return 0
            case "RB": return 1
            case "RB/WR": return 2
            case "WR": return 3
            case "WR/TE": return 4
            case "TE": return 5
            case "FLEX", "OP": return 6
            case "D/ST": return 7
            case "K": return 8
            case "P": return 9
            default: return 10
            }
        case .bench: return 20
        case .injuredReserve: return 21
        }
    }

    /// ESPN's slot ids. 20 is the bench and 21 is IR; everything else is a starting
    /// slot of some kind, so an unrecognised id counts toward your score rather than
    /// being silently dropped from the lineup.
    public static func from(id: Int?) -> LineupSlot {
        guard let id else { return .bench }
        switch id {
        case 20: return .bench
        case 21: return .injuredReserve
        case 0: return .starting("QB")
        case 1: return .starting("TQB")
        case 2: return .starting("RB")
        case 3: return .starting("RB/WR")
        case 4: return .starting("WR")
        case 5: return .starting("WR/TE")
        case 6: return .starting("TE")
        case 7: return .starting("OP")
        case 16: return .starting("D/ST")
        case 17: return .starting("K")
        case 18: return .starting("P")
        case 23: return .starting("FLEX")
        default: return .starting("FLEX")
        }
    }
}

public enum FantasyPosition: String, Sendable, Hashable {
    case quarterback = "QB"
    case runningBack = "RB"
    case wideReceiver = "WR"
    case tightEnd = "TE"
    case kicker = "K"
    case defense = "D/ST"
    case other = "—"

    public static func from(id: Int?) -> FantasyPosition {
        switch id {
        case 1: return .quarterback
        case 2: return .runningBack
        case 3: return .wideReceiver
        case 4: return .tightEnd
        case 5: return .kicker
        case 16: return .defense
        default: return .other
        }
    }
}

public struct RosterPlayer: Identifiable, Hashable, Sendable {
    /// ESPN athlete id — the same id the NFL boxscore uses, so this joins directly.
    public var id: Int
    public var fullName: String
    public var firstName: String
    public var lastName: String
    public var position: FantasyPosition
    public var slot: LineupSlot
    /// NFL team id, matching the site API's team ids.
    public var proTeamID: Int?
    public var points: Double
    public var injuryStatus: String?
    /// ESPN's projection for this player's whole week, fixed before kickoff. Nil when
    /// ESPN sent none, which is different from a projection of zero (a player on bye).
    public var projectedPoints: Double?

    public init(id: Int, fullName: String, firstName: String, lastName: String,
                position: FantasyPosition, slot: LineupSlot, proTeamID: Int?,
                points: Double, injuryStatus: String?, projectedPoints: Double? = nil) {
        self.id = id
        self.fullName = fullName
        self.firstName = firstName
        self.lastName = lastName
        self.position = position
        self.slot = slot
        self.proTeamID = proTeamID
        self.points = points
        self.injuryStatus = injuryStatus
        self.projectedPoints = projectedPoints
    }

    /// How ESPN's play text writes this player: "J.Smith-Njigba".
    public var playFeedName: String {
        let surname = PlayAttribution.baseSurname(lastName)
        guard let initial = firstName.first else { return surname }
        return "\(initial).\(surname)"
    }

    public var isStarter: Bool { slot.isStarter }
}

public struct FantasyTeam: Identifiable, Hashable, Sendable {
    public var id: Int
    public var name: String
    public var abbreviation: String
    public var points: Double
    public var roster: [RosterPlayer]
    /// ESPN's live projected final: points so far plus what it still expects.
    public var projectedPoints: Double?

    public init(id: Int, name: String, abbreviation: String, points: Double,
                roster: [RosterPlayer], projectedPoints: Double? = nil) {
        self.id = id
        self.name = name
        self.abbreviation = abbreviation
        self.points = points
        self.roster = roster
        self.projectedPoints = projectedPoints
    }

    /// Starters in lineup order, so two teams can be read side by side.
    public var starters: [RosterPlayer] {
        roster.filter(\.isStarter).sorted {
            if $0.slot.sortOrder != $1.slot.sortOrder {
                return $0.slot.sortOrder < $1.slot.sortOrder
            }
            return $0.fullName < $1.fullName
        }
    }
    public var bench: [RosterPlayer] { roster.filter { !$0.isStarter } }
}

/// How ESPN has settled a matchup, from your side of it.
public enum MatchupOutcome: Sendable, Hashable {
    case won, lost, tied
}

/// Your matchup for the current week.
public struct FantasyMatchup: Sendable, Hashable {
    public var leagueName: String
    public var week: Int
    public var mine: FantasyTeam
    public var opponent: FantasyTeam?
    /// ESPN's own chance that you win, 0–1. Nil when ESPN did not send one.
    public var espnWinProbability: Double?
    /// Nil until ESPN declares a winner, which it does not do until the week settles.
    public var outcome: MatchupOutcome?
    /// The scoring period the players' points are for. Usually the same number as
    /// `week`, but a playoff matchup can span two.
    public var scoringPeriod: Int?
    /// What each stat is worth in this league, for scoring plays as they happen. Empty
    /// when ESPN sent no scoring table, and then no play is worth anything.
    public var scoringRules: FantasyScoringRules

    public init(leagueName: String, week: Int, mine: FantasyTeam, opponent: FantasyTeam?,
                espnWinProbability: Double? = nil, outcome: MatchupOutcome? = nil,
                scoringPeriod: Int? = nil, scoringRules: FantasyScoringRules = FantasyScoringRules()) {
        self.leagueName = leagueName
        self.week = week
        self.mine = mine
        self.opponent = opponent
        self.espnWinProbability = espnWinProbability
        self.outcome = outcome
        self.scoringPeriod = scoringPeriod
        self.scoringRules = scoringRules
    }

    public var margin: Double { mine.points - (opponent?.points ?? 0) }
    public var isLeading: Bool { margin > 0 }

    /// Everyone in the matchup, tagged with which side they are on. The lookup the
    /// play map and the alert rules both work from.
    public var allPlayers: [(player: RosterPlayer, isMine: Bool)] {
        mine.roster.map { ($0, true) } + (opponent?.roster ?? []).map { ($0, false) }
    }

    public func players(onNFLTeam teamID: Int) -> [(player: RosterPlayer, isMine: Bool)] {
        allPlayers.filter { $0.player.proTeamID == teamID }
    }

    /// Score line sized for a menu bar: "78.2 – 71.5".
    public var compactScore: String {
        let me = String(format: "%.1f", mine.points)
        guard let opponent else { return me }
        return "\(me) – \(String(format: "%.1f", opponent.points))"
    }
}
