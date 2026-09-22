import Foundation

/// Which week the scoreboard should be showing.
///
/// ESPN's NFL week is not the calendar week and does not end when the football does.
/// Each week owns a window running Wednesday 07:00Z to the next Wednesday 06:59Z, and
/// `/scoreboard` with no parameters answers for whichever window contains "now". So
/// from the moment Monday night football ends until Wednesday morning UTC — a little
/// over a day, every week of the season — the default scoreboard is a complete set of
/// finals and the upcoming slate is nowhere in it.
///
/// That is the whole of the "week 2 hasn't shown up yet" problem: nothing was broken
/// in the app, it was being handed last week on purpose. `ESPNClient` asks for the next
/// week explicitly once the current one has no football left in it, and this works out
/// which week that is from the calendar ESPN ships in the same response.
public enum ScoreboardCalendar {

    /// A week to ask ESPN for, as the `week` and `seasontype` query parameters want it.
    public struct Week: Equatable, Sendable {
        public var number: Int
        public var seasonType: Int

        public init(number: Int, seasonType: Int) {
            self.number = number
            self.seasonType = seasonType
        }
    }

    /// The week after the one containing `now`, or `nil` if the calendar does not say.
    ///
    /// Crossing into the next season type is handled by flattening every week of every
    /// type into one list in the order ESPN gives them, so week 18 is followed by the
    /// Wild Card round rather than by a week 19 that does not exist. The preseason runs
    /// into the regular season the same way. Past the last week of the calendar — the
    /// Super Bowl, and the off-season entry that follows it — there is no next week and
    /// the answer is `nil`.
    public static func nextWeek(after now: Date, in dto: ESPNScoreboardDTO) -> Week? {
        let weeks = allWeeks(in: dto)
        guard !weeks.isEmpty else { return nil }

        // The window containing `now`. ESPN's windows are contiguous, so at most one
        // matches; a gap (or a date ESPN has not covered) falls through to the first
        // week that has not started yet, which is the same answer.
        if let index = weeks.firstIndex(where: { $0.start <= now && now <= $0.end }) {
            let next = index + 1
            return next < weeks.count ? weeks[next].week : nil
        }
        return weeks.first { $0.start > now }?.week
    }

    /// Every week ESPN lists, in calendar order, with the window each one owns.
    ///
    /// The off-season is a season type with no weeks in it, so it drops out here and
    /// cannot be returned as somewhere to look for games.
    static func allWeeks(in dto: ESPNScoreboardDTO) -> [Window] {
        let seasons = (dto.leagues ?? []).compacted().first?.calendar ?? []
        return seasons.compacted().flatMap { season -> [Window] in
            guard let seasonType = season.value.flatMap({ Int($0) }) else { return [] }
            return (season.entries ?? []).compacted().compactMap { entry in
                guard
                    let number = entry.value.flatMap({ Int($0) }),
                    let start = date(from: entry.startDate),
                    let end = date(from: entry.endDate)
                else { return nil }
                return Window(week: Week(number: number, seasonType: seasonType),
                              start: start, end: end)
            }
        }
    }

    /// One week and the stretch of time ESPN considers it to own.
    struct Window {
        var week: Week
        var start: Date
        var end: Date
    }

    /// The calendar's timestamps are the same second-less UTC shape as a kickoff —
    /// `2026-09-16T07:00Z` — so they go through the same parser.
    static func date(from string: String?) -> Date? {
        ESPNMapper.parseDate(string)
    }
}
