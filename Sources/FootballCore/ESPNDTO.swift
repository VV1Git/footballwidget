import Foundation

// Wire types for ESPN's public (undocumented) NFL endpoints.
//
// Everything is optional on purpose. These payloads are not a contract — fields come
// and go depending on whether a game is scheduled, live, at halftime or final, and
// ESPN reshapes them without notice. Decoding must never throw over a missing key;
// the UI degrades instead.

/// Decodes an element, or yields `nil` instead of throwing.
///
/// Used for array elements so that one malformed game or play cannot take down the
/// whole slate. ESPN genuinely does reshape fields between endpoints — `broadcasts.market`
/// is a `String` on the scoreboard and an object on the summary — so all-or-nothing
/// decoding is not safe here.
public struct Failable<T: Decodable & Sendable>: Decodable, Sendable {
    public let value: T?
    public init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

public extension Array {
    /// Drops the elements that failed to decode.
    func compacted<T>() -> [T] where Element == Failable<T> {
        compactMap(\.value)
    }
}

// MARK: - Shared

public struct ESPNTeamDTO: Decodable, Sendable {
    public var id: String?
    public var abbreviation: String?
    public var displayName: String?
    public var shortDisplayName: String?
    public var location: String?
    public var name: String?
    public var color: String?
    public var alternateColor: String?
    public var logo: String?
}

public struct ESPNRecordDTO: Decodable, Sendable {
    public var type: String?
    public var summary: String?
}

public struct ESPNStatusTypeDTO: Decodable, Sendable {
    public var id: String?
    public var name: String?
    public var state: String?       // "pre" | "in" | "post"
    public var completed: Bool?
    public var description: String?
    public var detail: String?
    public var shortDetail: String?
}

public struct ESPNStatusDTO: Decodable, Sendable {
    public var clock: Double?
    public var displayClock: String?
    public var period: Int?
    public var type: ESPNStatusTypeDTO?
}

// MARK: - Scoreboard

public struct ESPNScoreboardDTO: Decodable, Sendable {
    public var events: [Failable<ESPNEventDTO>]?
    /// Which week this response is for. ESPN picks it from the calendar below, not
    /// from the date, so it is last week's number all of Tuesday.
    public var week: ESPNWeekDTO?
    public var season: ESPNSeasonDTO?
    public var leagues: [Failable<ESPNLeagueDTO>]?
}

public struct ESPNWeekDTO: Decodable, Sendable {
    public var number: Int?
}

public struct ESPNSeasonDTO: Decodable, Sendable {
    /// 1 preseason, 2 regular season, 3 postseason.
    public var type: Int?
    public var year: Int?
}

public struct ESPNLeagueDTO: Decodable, Sendable {
    /// One entry per season type, each holding that type's weeks.
    public var calendar: [Failable<ESPNCalendarSeasonDTO>]?
}

/// A season type — "Regular Season", "Postseason" — and the weeks inside it.
public struct ESPNCalendarSeasonDTO: Decodable, Sendable {
    public var label: String?
    /// The season type as a string, matching `season.type`: "2" for the regular season.
    public var value: String?
    public var entries: [Failable<ESPNCalendarEntryDTO>]?
}

/// One week, with the window ESPN considers it to own. The windows run Wednesday
/// 07:00Z to the following Wednesday 06:59Z, which is why the scoreboard still
/// answers with last week's finals on a Tuesday.
public struct ESPNCalendarEntryDTO: Decodable, Sendable {
    public var label: String?
    /// The week number as a string: "2".
    public var value: String?
    public var startDate: String?
    public var endDate: String?
}

public struct ESPNEventDTO: Decodable, Sendable {
    public var id: String?
    public var date: String?
    public var name: String?
    public var shortName: String?
    public var status: ESPNStatusDTO?
    public var competitions: [Failable<ESPNCompetitionDTO>]?
}

public struct ESPNCompetitionDTO: Decodable, Sendable {
    public var id: String?
    public var date: String?
    public var status: ESPNStatusDTO?
    public var competitors: [Failable<ESPNCompetitorDTO>]?
    public var situation: ESPNSituationDTO?
    public var broadcasts: [ESPNBroadcastDTO]?
    public var venue: ESPNVenueDTO?
}

public struct ESPNBroadcastDTO: Decodable, Sendable {
    public var names: [String]?
}

public struct ESPNVenueDTO: Decodable, Sendable {
    public var fullName: String?
}

public struct ESPNCompetitorDTO: Decodable, Sendable {
    public var id: String?
    public var homeAway: String?
    /// Scoreboard sends this as a *string* ("17"), unlike the play feed which uses Int.
    public var score: String?
    public var winner: Bool?
    public var team: ESPNTeamDTO?
    public var records: [ESPNRecordDTO]?
}

public struct ESPNSituationDTO: Decodable, Sendable {
    public var down: Int?
    public var distance: Int?
    public var yardLine: Int?
    public var downDistanceText: String?
    public var shortDownDistanceText: String?
    public var possessionText: String?
    public var isRedZone: Bool?
    public var homeTimeouts: Int?
    public var awayTimeouts: Int?
    /// Team id currently in possession.
    public var possession: String?
    public var lastPlay: ESPNPlayDTO?
}

// MARK: - Summary (drives + play by play)

public struct ESPNSummaryDTO: Decodable, Sendable {
    public var drives: ESPNDrivesDTO?
    public var scoringPlays: [Failable<ESPNScoringPlayDTO>]?
    /// The game's own status and score as the play feed has it — often ahead of the
    /// scoreboard's. See `Game.reconciled(with:)`.
    public var header: ESPNSummaryHeaderDTO?
}

public struct ESPNSummaryHeaderDTO: Decodable, Sendable {
    public var competitions: [Failable<ESPNSummaryCompetitionDTO>]?
}

public struct ESPNSummaryCompetitionDTO: Decodable, Sendable {
    public var status: ESPNStatusDTO?
    public var competitors: [Failable<ESPNCompetitorDTO>]?
}

public struct ESPNDrivesDTO: Decodable, Sendable {
    public var current: ESPNDriveDTO?
    public var previous: [Failable<ESPNDriveDTO>]?
}

public struct ESPNDriveDTO: Decodable, Sendable {
    public var id: String?
    public var description: String?
    public var displayResult: String?
    public var shortDisplayResult: String?
    public var result: String?
    public var isScore: Bool?
    public var yards: Int?
    public var offensivePlays: Int?
    public var timeElapsed: ESPNClockDTO?
    public var team: ESPNTeamDTO?
    public var start: ESPNDriveEndpointDTO?
    public var end: ESPNDriveEndpointDTO?
    public var plays: [Failable<ESPNPlayDTO>]?
}

public struct ESPNDriveEndpointDTO: Decodable, Sendable {
    public var period: ESPNPeriodDTO?
    public var clock: ESPNClockDTO?
    public var yardLine: Int?
    public var text: String?
}

public struct ESPNPeriodDTO: Decodable, Sendable {
    public var number: Int?
}

public struct ESPNClockDTO: Decodable, Sendable {
    public var value: Double?
    public var displayValue: String?
}

public struct ESPNPlayTypeDTO: Decodable, Sendable {
    public var id: String?
    public var text: String?
    public var abbreviation: String?
}

/// What kind of score a scoring play was. `abbreviation` is "TD", "FG" or "SF".
public struct ESPNScoringTypeDTO: Decodable, Sendable {
    public var name: String?
    public var abbreviation: String?
}

public struct ESPNPlayDTO: Decodable, Sendable {
    public var id: String?
    public var sequenceNumber: String?
    public var type: ESPNPlayTypeDTO?
    public var text: String?
    public var shortText: String?
    /// Play feed uses Int scores, unlike the scoreboard's strings.
    public var awayScore: Int?
    public var homeScore: Int?
    public var period: ESPNPeriodDTO?
    public var clock: ESPNClockDTO?
    public var scoringPlay: Bool?
    public var scoringType: ESPNScoringTypeDTO?
    public var isPenalty: Bool?
    public var isTurnover: Bool?
    public var statYardage: Int?
    public var start: ESPNPlayNodeDTO?
    public var end: ESPNPlayNodeDTO?
}

/// One end of a play. `team` says whose frame `yardsToEndzone` is measured in, and it
/// is *not* always the team on offense — it flips on kickoffs and turnover returns.
public struct ESPNPlayNodeDTO: Decodable, Sendable {
    public var down: Int?
    public var distance: Int?
    public var yardLine: Int?
    public var yardsToEndzone: Int?
    public var downDistanceText: String?
    public var shortDownDistanceText: String?
    public var possessionText: String?
    public var team: ESPNTeamRefDTO?
}

public struct ESPNTeamRefDTO: Decodable, Sendable {
    public var id: String?
}

public struct ESPNScoringPlayDTO: Decodable, Sendable {
    public var id: String?
    public var type: ESPNPlayTypeDTO?
    public var text: String?
    public var awayScore: Int?
    public var homeScore: Int?
    public var period: ESPNPeriodDTO?
    public var clock: ESPNClockDTO?
    public var team: ESPNTeamDTO?
}
