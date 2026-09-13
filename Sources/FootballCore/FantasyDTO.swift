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
    public var scoringPeriodId: Int?
    public var statSourceId: Int?      // 0 = actual, 1 = projected
    public var statSplitTypeId: Int?
    public var appliedTotal: Double?
}

public struct FantasyMatchupDTO: Decodable, Sendable {
    public var id: Int?
    public var matchupPeriodId: Int?
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
    public var totalProjectedPointsLive: Double?
    public var rosterForCurrentScoringPeriod: FantasyRosterDTO?
    public var rosterForMatchupPeriod: FantasyRosterDTO?
}
