import Foundation
import Testing
@testable import FootballCore

private enum Fixture {
    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json",
                                          subdirectory: "Fixtures") else {
            throw FixtureError.missing(name)
        }
        return try Data(contentsOf: url)
    }

    static func scoreboard() throws -> ESPNScoreboardDTO {
        try JSONDecoder().decode(ESPNScoreboardDTO.self, from: data("scoreboard"))
    }

    static func summary() throws -> ESPNSummaryDTO {
        try JSONDecoder().decode(ESPNSummaryDTO.self, from: data("summary"))
    }

    enum FixtureError: Error { case missing(String) }
}

// MARK: - Decoding

@Test func scoreboardDecodesEveryGame() throws {
    let games = ESPNMapper.games(from: try Fixture.scoreboard())
    #expect(games.count == 16)

    let opener = try #require(games.first { $0.shortName == "NE @ SEA" })
    #expect(opener.phase == .final)
    #expect(opener.home.abbreviation == "SEA")
    #expect(opener.away.abbreviation == "NE")
    #expect(opener.home.score == 13)
    #expect(opener.away.score == 10)
    #expect(opener.home.primaryHex == "002a5c")
    #expect(opener.home.logoURL != nil)
    #expect(opener.periodLabel == "FINAL")
}

/// ESPN omits seconds (`2026-09-10T00:20Z`), which trips the stock ISO8601 parser.
@Test func kickoffDateParsesWithoutSeconds() throws {
    let date = try #require(ESPNMapper.parseDate("2026-09-10T00:20Z"))
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: 0)!
    let parts = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    #expect(parts.year == 2026 && parts.month == 9 && parts.day == 10)
    #expect(parts.hour == 0 && parts.minute == 20)

    #expect(ESPNMapper.parseDate("2026-09-10T00:20:30Z") != nil)
    #expect(ESPNMapper.parseDate(nil) == nil)
    #expect(ESPNMapper.parseDate("not a date") == nil)
}

@Test func scheduledGameHasNoSituation() throws {
    let games = ESPNMapper.games(from: try Fixture.scoreboard())
    let upcoming = try #require(games.first { $0.phase == .pre })
    #expect(upcoming.situation == nil)
    #expect(upcoming.home.score == 0)
    #expect(upcoming.kickoff != nil)
}

@Test func summaryDecodesAllDrives() throws {
    let detail = ESPNMapper.detail(from: try Fixture.summary(), gameID: "401872656")
    #expect(detail.drives.count == 19)
    #expect(detail.scoringPlayIDs.count == 5)
    // Newest drive first.
    #expect(detail.drives.first?.result == "End of Game")
}

// MARK: - Classification

@Test func administrativePlaysAreClassifiedNotDrawn() {
    let blank = PlayNode(teamID: "17", yardsToEndzone: 0)
    let spot = PlayNode(teamID: "17", yardsToEndzone: 47)
    for id in ["2", "21", "65", "66", "74", "75"] {
        #expect(FieldGeometry.classify(typeID: id, isTurnover: false, start: blank, end: spot)
                == .administrative, "type \(id) should be administrative")
    }
    // Unknown clock event still caught by the fallback heuristic.
    #expect(FieldGeometry.classify(typeID: "9999", isTurnover: false, start: blank, end: spot)
            == .administrative)
}

@Test func possessionChangingPlaysAreClassified() {
    let a = PlayNode(teamID: "17", yardsToEndzone: 40)
    let b = PlayNode(teamID: "26", yardsToEndzone: 55)
    #expect(FieldGeometry.classify(typeID: "52", isTurnover: false, start: a, end: b) == .changeOfPossession)
    #expect(FieldGeometry.classify(typeID: "26", isTurnover: true, start: a, end: b) == .changeOfPossession)
    #expect(FieldGeometry.classify(typeID: "53", isTurnover: false, start: a, end: b) == .kickoff)
    #expect(FieldGeometry.classify(typeID: "5", isTurnover: false, start: a, end: a) == .scrimmage)
}

// MARK: - Coordinates

@Test func coordinatesMirrorWhenTheFrameFlips() {
    // Same frame as the offense: 16 yards out means 84% of the way down the field.
    let own = PlayNode(teamID: "17", yardsToEndzone: 16)
    #expect(FieldGeometry.normalizedX(node: own, offenseTeamID: "17") == 0.84)

    // The other team's frame: 80 to *their* end zone is the same physical spot as
    // 20 to ours, so it must mirror to 0.80 rather than reading as 0.20.
    let flipped = PlayNode(teamID: "26", yardsToEndzone: 80)
    #expect(FieldGeometry.normalizedX(node: flipped, offenseTeamID: "17") == 0.80)

    // No team attribution: assume the offense's frame.
    let bare = PlayNode(teamID: nil, yardsToEndzone: 25)
    #expect(FieldGeometry.normalizedX(node: bare, offenseTeamID: "17") == 0.75)

    #expect(FieldGeometry.normalizedX(node: PlayNode(), offenseTeamID: "17") == nil)
}

// MARK: - The ladder, against a real drive

private func longestDrive() throws -> Drive {
    let detail = ESPNMapper.detail(from: try Fixture.summary(), gameID: "401872656")
    return try #require(detail.drives.max { $0.plays.count < $1.plays.count })
}

@Test func ladderDropsAdministrativePlaysAndKeepsSnaps() throws {
    let drive = try longestDrive()
    #expect(drive.plays.count == 23)          // raw feed
    let rows = FieldGeometry.rows(for: drive)
    #expect(rows.count == 18)                 // 5 timeouts / two-minute warnings removed
    #expect(rows.allSatisfy { $0.play.kind != .administrative })
}

@Test func ladderRendersKickoffAsTheDriveStart() throws {
    let rows = FieldGeometry.rows(for: try longestDrive())
    let first = try #require(rows.first)
    #expect(first.isDriveStart)
    #expect(first.play.kind == .kickoff)
    // A start marker has no length.
    #expect(first.startX == first.endX)
}

/// The regression that motivated the mirror: an interception returned a few yards
/// must draw as a short backwards bar, not a sweep across most of the field.
@Test func turnoverReturnStaysInTheOffensiveFrame() throws {
    let rows = FieldGeometry.rows(for: try longestDrive())
    let last = try #require(rows.last)
    #expect(last.flipsFrame)
    #expect(last.play.isTurnover)
    #expect(abs(last.startX - 0.84) < 0.001)
    #expect(abs(last.endX - 0.80) < 0.001)
    #expect(abs(last.endX - last.startX) < 0.10)  // unmirrored this was 0.64
}

@Test func everyRowStaysOnTheField() throws {
    let detail = ESPNMapper.detail(from: try Fixture.summary(), gameID: "401872656")
    for drive in detail.drives {
        for row in FieldGeometry.rows(for: drive) {
            #expect((0...1).contains(row.startX), "\(drive.teamAbbreviation) startX \(row.startX)")
            #expect((0...1).contains(row.endX), "\(drive.teamAbbreviation) endX \(row.endX)")
        }
    }
}

@Test func penaltiesAndSacksDrawBackwards() throws {
    let rows = FieldGeometry.rows(for: try longestDrive())
    let penalties = rows.filter { $0.play.isPenalty }
    #expect(!penalties.isEmpty)
    #expect(penalties.allSatisfy { $0.isBackwards })
}

/// The fantasy integration joins rosters to games on this id, so it has to be the NFL
/// team id — the same numbering ESPN's fantasy API uses for `proTeamId`.
@Test func teamIDsAreNFLTeamIDs() throws {
    let games = ESPNMapper.games(from: try Fixture.scoreboard())
    let opener = try #require(games.first { $0.shortName == "NE @ SEA" })
    #expect(opener.home.id == "26")   // Seattle
    #expect(opener.away.id == "17")   // New England
}
