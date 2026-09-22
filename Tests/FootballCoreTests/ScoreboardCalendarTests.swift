import Foundation
import Testing
@testable import FootballCore

/// The calendar as ESPN ships it inside the scoreboard response.
private func scoreboard() throws -> ESPNScoreboardDTO {
    let located = Bundle.module.url(forResource: "scoreboard", withExtension: "json",
                                    subdirectory: "Fixtures")
    let url = try #require(located)
    return try JSONDecoder().decode(ESPNScoreboardDTO.self, from: Data(contentsOf: url))
}

private func at(_ iso: String) throws -> Date {
    try #require(ESPNMapper.parseDate(iso))
}

// MARK: - The reported bug

/// Week 1 owns everything up to Wednesday 06:59Z, so on the Tuesday night after the
/// last game the default scoreboard is sixteen finals and week 2 is nowhere in it.
/// This is the moment the widget showed no upcoming games.
@Test func findsNextWeekOnTheTuesdayAfterTheWeekIsPlayedOut() throws {
    let next = ScoreboardCalendar.nextWeek(after: try at("2026-09-16T03:46Z"), in: try scoreboard())
    #expect(next == ScoreboardCalendar.Week(number: 2, seasonType: 2))
}

/// An hour later ESPN's own week has rolled over, and the default scoreboard is
/// already week 2 — nothing to substitute, and week 3 must not be reached for.
@Test func rollsOverToTheWeekAfterOnceESPNsWindowHasMoved() throws {
    let next = ScoreboardCalendar.nextWeek(after: try at("2026-09-16T08:00Z"), in: try scoreboard())
    #expect(next == ScoreboardCalendar.Week(number: 3, seasonType: 2))
}

// MARK: - Crossing the seams

/// There is no week 19. The postseason is a separate season type whose weeks number
/// from one again, which arithmetic on the week number alone would walk straight past.
@Test func week18IsFollowedByTheWildCardRoundNotAWeek19() throws {
    let next = ScoreboardCalendar.nextWeek(after: try at("2027-01-10T12:00Z"), in: try scoreboard())
    #expect(next == ScoreboardCalendar.Week(number: 1, seasonType: 3))
}

/// The same seam at the other end of the season.
@Test func theLastPreseasonWeekIsFollowedByTheRegularSeasonOpener() throws {
    let next = ScoreboardCalendar.nextWeek(after: try at("2026-09-01T12:00Z"), in: try scoreboard())
    #expect(next == ScoreboardCalendar.Week(number: 1, seasonType: 2))
}

/// After the Super Bowl there is only the off season, which lists no weeks. Nothing
/// to move on to, and nothing to invent.
@Test func thereIsNoWeekAfterTheLastOneOnTheCalendar() throws {
    #expect(ScoreboardCalendar.nextWeek(after: try at("2027-02-14T12:00Z"), in: try scoreboard()) == nil)
}

/// A date ESPN's calendar does not cover falls forward to the next week that starts,
/// rather than giving up.
@Test func aDateBeforeTheCalendarFallsForwardToItsFirstWeek() throws {
    let next = ScoreboardCalendar.nextWeek(after: try at("2026-07-01T12:00Z"), in: try scoreboard())
    #expect(next == ScoreboardCalendar.Week(number: 1, seasonType: 1))
}

// MARK: - Degrading

@Test func aResponseWithNoCalendarAsksForNothing() throws {
    let dto = try JSONDecoder().decode(ESPNScoreboardDTO.self, from: Data(#"{"events":[]}"#.utf8))
    #expect(ScoreboardCalendar.nextWeek(after: .now, in: dto) == nil)
}

/// The off-season entry carries no weeks, and an entry with no dates cannot be placed.
/// Neither may become somewhere to go looking for games.
@Test func entriesWithoutWeeksOrDatesAreSkipped() throws {
    let json = """
    {"leagues": [{"calendar": [
      {"label": "Off Season", "value": "4", "entries": []},
      {"label": "Regular Season", "value": "2", "entries": [
        {"label": "Week 1", "value": "1"},
        {"label": "Week 2", "value": "2",
         "startDate": "2026-09-16T07:00Z", "endDate": "2026-09-23T06:59Z"}
      ]}
    ]}]}
    """
    let dto = try JSONDecoder().decode(ESPNScoreboardDTO.self, from: Data(json.utf8))
    #expect(ScoreboardCalendar.allWeeks(in: dto).count == 1)
    let next = ScoreboardCalendar.nextWeek(after: try at("2026-09-10T12:00Z"), in: dto)
    #expect(next == ScoreboardCalendar.Week(number: 2, seasonType: 2))
}
