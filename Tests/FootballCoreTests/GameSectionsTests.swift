import Foundation
import Testing
@testable import FootballCore

private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}()

private func at(_ day: Int, _ hour: Int) -> Date {
    var parts = DateComponents()
    parts.year = 2026; parts.month = 9; parts.day = day; parts.hour = hour
    return calendar.date(from: parts)!
}

private func game(_ name: String, _ phase: GamePhase, kickoff: Date?) -> Game {
    Game(
        id: name, shortName: name, kickoff: kickoff, phase: phase,
        statusDetail: "", period: 0, displayClock: "",
        home: TeamSide(id: "1", abbreviation: "HOM", displayName: "HOM", shortName: "HOM", score: 0),
        away: TeamSide(id: "2", abbreviation: "AWY", displayName: "AWY", shortName: "AWY", score: 0)
    )
}

private let now = at(10, 16)   // Thursday afternoon

@Test func splitsTodayFromTheRestOfTheWeek() {
    let games = [
        game("TONIGHT", .pre, kickoff: at(10, 20)),
        game("SUNDAY", .pre, kickoff: at(13, 17)),
        game("MONDAY", .pre, kickoff: at(14, 0)),
    ]
    let sections = GameSections.build(games, now: now, calendar: calendar)
    #expect(sections.map(\.kind) == [.today, .week])
    #expect(sections[0].games.map(\.shortName) == ["TONIGHT"])
    #expect(sections[1].games.map(\.shortName) == ["SUNDAY", "MONDAY"])
}

/// A game that is being played belongs under Today even if its kickoff was yesterday
/// in local time — you should never lose the game you are watching to another section.
@Test func liveGamesCountAsTodayWhateverTheKickoff() {
    let games = [game("LATE", .live, kickoff: at(9, 23))]
    let sections = GameSections.build(games, now: now, calendar: calendar)
    #expect(sections.first?.kind == .today)
    #expect(sections.first?.liveCount == 1)
}

@Test func finishedGamesFromEarlierInTheWeekGoUnderThisWeek() {
    let games = [game("DONE", .final, kickoff: at(9, 20))]
    let sections = GameSections.build(games, now: now, calendar: calendar)
    #expect(sections.map(\.kind) == [.week])
}

@Test func todaysFinishedGameStaysUnderToday() {
    let games = [game("EARLIER", .final, kickoff: at(10, 10))]
    let sections = GameSections.build(games, now: now, calendar: calendar)
    #expect(sections.map(\.kind) == [.today])
}

@Test func emptySectionsAreOmitted() {
    let onlyLater = GameSections.build([game("SUN", .pre, kickoff: at(13, 17))],
                                       now: now, calendar: calendar)
    #expect(onlyLater.map(\.kind) == [.week])
    #expect(GameSections.build([], now: now, calendar: calendar).isEmpty)
}

@Test func sectionsKeepFavouritesFirstWithinThemselves() {
    let a = Game(id: "A", shortName: "A", kickoff: at(13, 17), phase: .pre,
                 statusDetail: "", period: 0, displayClock: "",
                 home: TeamSide(id: "1", abbreviation: "CIN", displayName: "", shortName: "", score: 0),
                 away: TeamSide(id: "2", abbreviation: "TB", displayName: "", shortName: "", score: 0))
    let b = Game(id: "B", shortName: "B", kickoff: at(14, 0), phase: .pre,
                 statusDetail: "", period: 0, displayClock: "",
                 home: TeamSide(id: "3", abbreviation: "KC", displayName: "", shortName: "", score: 0),
                 away: TeamSide(id: "4", abbreviation: "DEN", displayName: "", shortName: "", score: 0))
    let sections = GameSections.build([a, b], favorites: ["DEN"], now: now, calendar: calendar)
    #expect(sections.first?.games.map(\.id) == ["B", "A"])
}

@Test func countLabelReadsNaturally() {
    let one = GameSection(kind: .today, games: [game("X", .pre, kickoff: at(10, 20))])
    #expect(one.countLabel == "1 game")
    let many = GameSection(kind: .week, games: (1...15).map { game("G\($0)", .pre, kickoff: at(13, 17)) })
    #expect(many.countLabel == "15 games")
}
