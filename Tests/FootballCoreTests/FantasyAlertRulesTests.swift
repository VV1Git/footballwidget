import Foundation
import Testing
@testable import FootballCore

private func player(
    _ id: Int, _ first: String, _ last: String,
    slot: LineupSlot = .starting("WR"), points: Double = 0
) -> RosterPlayer {
    RosterPlayer(id: id, fullName: "\(first) \(last)", firstName: first, lastName: last,
                 position: .wideReceiver, slot: slot, proTeamID: 4, points: points,
                 injuryStatus: nil)
}

private func matchup(mine: Double = 78.2, theirs: Double? = 71.5) -> FantasyMatchup {
    FantasyMatchup(
        leagueName: "Test League",
        week: 1,
        mine: FantasyTeam(id: 1, name: "My Team", abbreviation: "ME", points: mine, roster: []),
        opponent: theirs.map {
            FantasyTeam(id: 2, name: "Their Team", abbreviation: "OPP", points: $0, roster: [])
        }
    )
}

private func moment(
    delta: Double,
    touchdown: Bool = false,
    slot: LineupSlot = .starting("WR"),
    isMine: Bool = true,
    total: Double = 26.7,
    text: String? = "(Shotgun) J.Burrow pass short left to J.Chase for 4 yards, TOUCHDOWN. E.McPherson extra point is GOOD, Center-W.Wagner, Holder-R.Rehkow."
) -> FantasyMoment {
    FantasyMoment(
        player: player(1, "Ja'Marr", "Chase", slot: slot, points: total),
        isMine: isMine, delta: delta, playText: text, isTouchdown: touchdown
    )
}

// MARK: - Threshold

@Test func touchdownsAlwaysQualify() {
    let events = FantasyAlertRules.events(
        moments: [moment(delta: 0.4, touchdown: true)],
        matchup: matchup(), settings: FantasyAlertSettings()
    )
    #expect(events.count == 1)
}

@Test func smallPlaysAreIgnored() {
    for delta in [0.3, 1.0, 4.9, 5.99] {
        let events = FantasyAlertRules.events(
            moments: [moment(delta: delta)], matchup: matchup(),
            settings: FantasyAlertSettings(threshold: 6.0)
        )
        #expect(events.isEmpty, "\(delta) should not alert")
    }
}

@Test func bigNonScoringPlaysQualify() {
    let events = FantasyAlertRules.events(
        moments: [moment(delta: 6.0, touchdown: false)],
        matchup: matchup(), settings: FantasyAlertSettings(threshold: 6.0)
    )
    #expect(events.count == 1)
}

@Test func thresholdIsConfigurable() {
    let quiet = FantasyAlertRules.events(
        moments: [moment(delta: 8.0)], matchup: matchup(),
        settings: FantasyAlertSettings(threshold: 12.0)
    )
    #expect(quiet.isEmpty)
}

// MARK: - Who counts

@Test func benchPlayersStayQuiet() {
    let events = FantasyAlertRules.events(
        moments: [moment(delta: 12.0, touchdown: true, slot: .bench)],
        matchup: matchup(), settings: FantasyAlertSettings()
    )
    #expect(events.isEmpty)
}

@Test func opponentStartersDoAlert() throws {
    let events = FantasyAlertRules.events(
        moments: [moment(delta: 12.0, touchdown: true, isMine: false)],
        matchup: matchup(), settings: FantasyAlertSettings()
    )
    let event = try #require(events.first)
    #expect(event.title.hasPrefix("Opp · "))
}

@Test func yourPlayersAreMarkedAsYours() throws {
    let event = try #require(FantasyAlertRules.events(
        moments: [moment(delta: 12.0, touchdown: true)],
        matchup: matchup(), settings: FantasyAlertSettings()
    ).first)
    #expect(event.title.hasPrefix("Yours · "))
}

/// ESPN revises stats hours after a game. Totals should follow, banners should not.
@Test func downwardCorrectionsNeverAlert() {
    let events = FantasyAlertRules.events(
        moments: [moment(delta: -6.0, touchdown: true)],
        matchup: matchup(), settings: FantasyAlertSettings()
    )
    #expect(events.isEmpty)
}

@Test func disablingSilencesEverything() {
    let events = FantasyAlertRules.events(
        moments: [moment(delta: 20.0, touchdown: true)],
        matchup: matchup(), settings: FantasyAlertSettings(enabled: false)
    )
    #expect(events.isEmpty)
}

// MARK: - Notification text

/// Title and subtitle carry the player, the points and the matchup; the body is his side
/// of the play in a few words rather than the whole gamebook sentence.
@Test func notificationTextFitsABanner() throws {
    let long = "(Shotgun) J.Burrow pass deep right to J.Chase for 63 yards, TOUCHDOWN. "
             + "The Replay Official reviewed the runner broke the plane ruling, and the play was upheld."
    let event = try #require(FantasyAlertRules.events(
        moments: [moment(delta: 12.4, touchdown: true, text: long)],
        matchup: matchup(), settings: FantasyAlertSettings()
    ).first)

    #expect(event.title == "Yours · Ja'Marr Chase +12.4")
    #expect(event.title.count <= AlertRules.titleLimit)
    let subtitle = try #require(event.subtitle)
    #expect(subtitle == "TD · 26.7 total · You 78.2 – 71.5")
    #expect(subtitle.count <= AlertRules.subtitleLimit)
    #expect(event.body == "63-yd catch from J. Burrow")
}

/// The same play reads differently depending on whose side of it you are on.
@Test func playLineIsFromThePlayersPointOfView() throws {
    let text = "(Shotgun) J.Burrow pass short left to J.Chase for 4 yards, TOUCHDOWN. E.McPherson extra point is GOOD, Center-W.Wagner, Holder-R.Rehkow."
    let passer = FantasyMoment(
        player: RosterPlayer(id: 2, fullName: "Joe Burrow", firstName: "Joe", lastName: "Burrow",
                             position: .quarterback, slot: .starting("QB"), proTeamID: 4, points: 20, injuryStatus: nil),
        isMine: true, delta: 6, playText: text, isTouchdown: true)
    #expect(FantasyAlertRules.playLine(for: passer) == "4-yd pass to J. Chase")

    let rusher = FantasyMoment(
        player: RosterPlayer(id: 3, fullName: "Chase Brown", firstName: "Chase", lastName: "Brown",
                             position: .runningBack, slot: .starting("RB"), proTeamID: 4, points: 20, injuryStatus: nil),
        isMine: true, delta: 6.5, playText: "C.Brown up the middle for 5 yards, TOUCHDOWN. E.McPherson extra point is GOOD, Center-W.Wagner, Holder-R.Rehkow.",
        isTouchdown: true)
    #expect(FantasyAlertRules.playLine(for: rusher) == "5-yd run")
}

/// A play the parser cannot read from his side still loses the clutter.
@Test func unreadablePlaysAreCondensed() {
    #expect(FantasyAlertRules.condensed("(Shotgun) J.Burrow sacked at CIN 30 for -7 yards (T.Watt).")
            == "J.Burrow sacked at CIN 30 for -7 yards (T.Watt).")
    #expect(FantasyAlertRules.condensed("E.McPherson extra point is GOOD, Center-W.Wagner, Holder-R.Rehkow.")
            == "E.McPherson extra point is GOOD.")
}

@Test func handlesAMissingPlayDescription() throws {
    let event = try #require(FantasyAlertRules.events(
        moments: [moment(delta: 9.0, text: nil)],
        matchup: matchup(), settings: FantasyAlertSettings()
    ).first)
    #expect(event.body.contains("Ja'Marr Chase"))
}

@Test func handlesAByeWeekWithNoOpponent() throws {
    let event = try #require(FantasyAlertRules.events(
        moments: [moment(delta: 9.0)],
        matchup: matchup(theirs: nil), settings: FantasyAlertSettings()
    ).first)
    let subtitle = try #require(event.subtitle)
    #expect(subtitle.contains("You 78.2"))
}

/// The id is the de-duplication key in AlertEngine, so a second score by the same
/// player must produce a different one.
@Test func eventIDsSeparateSuccessiveScores() throws {
    let first = try #require(FantasyAlertRules.event(
        for: moment(delta: 12.4, touchdown: true, total: 12.4),
        matchup: matchup(), settings: FantasyAlertSettings()
    ))
    let second = try #require(FantasyAlertRules.event(
        for: moment(delta: 12.4, touchdown: true, total: 24.8),
        matchup: matchup(), settings: FantasyAlertSettings()
    ))
    #expect(first.id != second.id)
}
