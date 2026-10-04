import Foundation

// Wire types for ESPN's fantasy football API (lm-api-reads.fantasy.espn.com).
//
// Same rules as the NFL DTOs: everything optional, array elements wrapped in
// `Failable` so one odd roster entry cannot blank the whole matchup. This shape is
// inferred from ESPN's documented-by-nobody v3 API, so it is written to bend.

public struct FantasyLeagueDTO: Decodable, Sendable {
    public var id: Int?
    public var seasonId: Int?
    public var scoringPeriodId: Int?
    public var status: FantasyStatusDTO?
    public var settings: FantasySettingsDTO?
    public var members: [Failable<FantasyMemberDTO>]?
    public var teams: [Failable<FantasyTeamDTO>]?
    public var schedule: [Failable<FantasyMatchupDTO>]?
}

public struct FantasyStatusDTO: Decodable, Sendable {
    public var currentMatchupPeriod: Int?
    public var latestScoringPeriod: Int?
}

public struct FantasySettingsDTO: Decodable, Sendable {
    public var name: String?
    /// Wrapped so a scoring block in a shape not seen before costs the league its
    /// per-play points rather than the whole matchup.
    public var scoringSettings: Failable<FantasyScoringSettingsDTO>?
}

/// The league's scoring table, from `view=mSettings`.
public struct FantasyScoringSettingsDTO: Decodable, Sendable {
    public var scoringItems: [Failable<FantasyScoringItemDTO>]?
}

/// One line of the scoring table: what one unit of an ESPN stat is worth.
public struct FantasyScoringItemDTO: Decodable, Sendable {
    public var statId: Int?
    public var points: Double?
    /// Lineup slot id (as a string, being a JSON key) → points, where the league scores
    /// a stat differently for one position — a premium per catch for tight ends, say.
    public var pointsOverrides: [String: Double]?

    enum CodingKeys: String, CodingKey { case statId, points, pointsOverrides }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        statId = try? container.decodeIfPresent(Int.self, forKey: .statId)
        points = try? container.decodeIfPresent(Double.self, forKey: .points)
        // An override map that will not decode loses the overrides, not the item.
        pointsOverrides = try? container.decodeIfPresent([String: Double].self, forKey: .pointsOverrides)
    }
}

/// A human in the league. `id` is the SWID, braces and all.
public struct FantasyMemberDTO: Decodable, Sendable {
    public var id: String?
    public var displayName: String?
    public var firstName: String?
    public var lastName: String?
}

public struct FantasyTeamDTO: Decodable, Sendable {
    public var id: Int?
    public var abbrev: String?
    public var name: String?
    public var location: String?
    public var nickname: String?
    public var owners: [String]?
    public var logo: String?
    public var roster: FantasyRosterDTO?
}

public struct FantasyRosterDTO: Decodable, Sendable {
    /// The roster's live total for the week — the same number as `totalPointsLive`.
    public var appliedStatTotal: Double?
    public var entries: [Failable<FantasyRosterEntryDTO>]?
}

public struct FantasyRosterEntryDTO: Decodable, Sendable {
    public var playerId: Int?
    /// Which slot the player occupies. 20 is bench and 21 is IR; everything else is a
    /// starting slot.
    public var lineupSlotId: Int?
    public var playerPoolEntry: FantasyPlayerPoolEntryDTO?
}

public struct FantasyPlayerPoolEntryDTO: Decodable, Sendable {
    public var id: Int?
    /// Live fantasy points for the current scoring period.
    public var appliedStatTotal: Double?
    public var player: FantasyPlayerDTO?
}

public struct FantasyPlayerDTO: Decodable, Sendable {
    /// Identical to the athlete id in ESPN's NFL feeds — verified, not assumed.
    public var id: Int?
    public var fullName: String?
    public var firstName: String?
    public var lastName: String?
    public var defaultPositionId: Int?
    /// Identical to the NFL team id in ESPN's site API — also verified.
    public var proTeamId: Int?
    public var injuryStatus: String?
    public var stats: [Failable<FantasyPlayerStatDTO>]?
}

public struct FantasyPlayerStatDTO: Decodable, Sendable {
    public var seasonId: Int?
    /// 0 for a whole-season line. A real roster carries last season's total, this
    /// season's projected total and this week's projection side by side, so this is
    /// what separates "projected 16.9 this week" from "projected 328 this year".
    public var scoringPeriodId: Int?
    public var statSourceId: Int?      // 0 = actual, 1 = projected
    public var statSplitTypeId: Int?   // 0 = season, 1 = single scoring period
    public var appliedTotal: Double?
}

public struct FantasyMatchupDTO: Decodable, Sendable {
    public var id: Int?
    public var matchupPeriodId: Int?
    /// "HOME", "AWAY" or "TIE" once ESPN has settled the week; "UNDECIDED" until then,
    /// including the whole time the games are being played.
    public var winner: String?
    public var home: FantasyMatchupSideDTO?
    public var away: FantasyMatchupSideDTO?
}

public struct FantasyMatchupSideDTO: Decodable, Sendable {
    public var teamId: Int?
    /// The settled score for the matchup period. ESPN leaves this at zero until the
    /// week closes, so during the games it is not the score anyone wants.
    public var totalPoints: Double?
    /// The score as it stands right now. This is the one that moves during games.
    public var totalPointsLive: Double?
    /// Points scored plus what ESPN still expects from the lineup — the "Proj Total"
    /// on ESPN's own matchup screens. Unlike `totalProjectedPoints`, which is fixed at
    /// kickoff, this one moves during games.
    public var totalProjectedPointsLive: Double?
    /// ESPN's chance this side wins, 0–1 to two decimals, as shown under "Chance to Win"
    /// in FantasyCast. Carried by `mMatchupScore`, only for the matchup period in
    /// progress: a finished season's schedule has none. Verified against a live week.
    public var winProbability: Double?
    public var rosterForCurrentScoringPeriod: FantasyRosterDTO?
    public var rosterForMatchupPeriod: FantasyRosterDTO?
}
