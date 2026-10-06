import Foundation
import Testing
@testable import FootballCore

/// The scoring table from a real league payload (`view=mSettings`, recorded live), so the
/// per-play scorer is checked against ESPN's actual shape: kicks paid by distance bucket
/// and every team-defense value carried only as a D/ST slot override.

private func liveRules() throws -> FantasyScoringRules {
    let located = Bundle.module.url(forResource: "scoring-settings-live", withExtension: "json",
                                    subdirectory: "Fixtures")
    let url = try #require(located)
    let dto = try JSONDecoder().decode(FantasyScoringSettingsDTO.self, from: Data(contentsOf: url))
    return FantasyMapper.scoringRules(from: dto)
}

private let neAtSea = Game(
    id: "401872656", shortName: "NE @ SEA", phase: .live, statusDetail: "", period: 2,
    displayClock: "7:00",
    home: TeamSide(id: "26", abbreviation: "SEA", displayName: "SEA", shortName: "SEA", score: 0),
    away: TeamSide(id: "17", abbreviation: "NE", displayName: "NE", shortName: "NE", score: 0)
)

private func rostered(_ id: Int, _ first: String, _ last: String, _ position: FantasyPosition,
                      team: Int) -> RosterPlayer {
    RosterPlayer(id: id, fullName: "\(first) \(last)", firstName: first, lastName: last,
                 position: position, slot: .starting(position.rawValue), proTeamID: team,
                 points: 0, injuryStatus: nil)
}

private func play(_ text: String, offense: String = "17", touchdown: Bool = false) -> Play {
    Play(id: UUID().uuidString, sequence: 0, typeID: nil, typeText: "", text: text,
         downDistanceText: nil, yards: 0, period: 2, clock: "7:00",
         isScoring: touchdown, scoreKind: touchdown ? .touchdown : nil,
         isTurnover: false, isPenalty: false,
         start: PlayNode(teamID: offense), end: PlayNode(), kind: .scrimmage)
}

private func points(_ player: RosterPlayer, on text: String, offense: String = "17",
                    touchdown: Bool = false) throws -> Double {
    let rules = try liveRules()
    let drive = Drive(id: "d", teamID: offense, teamAbbreviation: "", result: "", isScore: false,
                      yards: 0, playCount: 1, timeElapsed: "", summary: "", startText: nil,
                      plays: [play(text, offense: offense, touchdown: touchdown)], isCurrent: true)
    let detail = GameDetail(gameID: neAtSea.id, drives: [drive], scoringPlayIDs: [])
    let lines = FantasyGameScorer(detail: detail, game: neAtSea).lines(for: player)
    let total = lines.reduce(0) { $0 + rules.points(for: $1.stats, position: player.position) }
    return (total * 100).rounded() / 100
}

private let diggs = rostered(2976212, "Stefon", "Diggs", .wideReceiver, team: 17)
private let borregales = rostered(4686474, "Andy", "Borregales", .kicker, team: 17)
private let seahawks = rostered(-16026, "Seahawks", "D/ST", .defense, team: 26)

@Test func liveTableDecodesWithItsOverrides() throws {
    let rules = try liveRules()
    #expect(!rules.isEmpty)
    #expect(rules.value(of: 53, for: .wideReceiver) == 1)
    #expect(rules.value(of: 99, for: .defense) == 1)        // a sack, only as a D/ST override
    #expect(rules.value(of: 99, for: .wideReceiver) == 0)
}

@Test func liveTablePaysAReception() throws {
    #expect(try points(diggs, on: "D.Maye pass short right to S.Diggs to NE 40 for 12 yards (D.Williams).") == 2.2)
}

/// This league pays field goals by distance: 3 under 40, 4 in the 40s, 5 in the 50s, and
/// takes a point for a miss.
@Test func liveTablePaysKicksByDistance() throws {
    #expect(try points(borregales, on: "A.Borregales 33 yard field goal is GOOD, Center-J.Ashby, Holder-M.Wishnowsky.") == 3)
    #expect(try points(borregales, on: "A.Borregales 45 yard field goal is GOOD, Center-J.Ashby, Holder-M.Wishnowsky.") == 4)
    #expect(try points(borregales, on: "A.Borregales 52 yard field goal is GOOD, Center-J.Ashby, Holder-M.Wishnowsky.") == 5)
    #expect(try points(borregales, on: "A.Borregales 47 yard field goal is No Good, Wide Right, Center-J.Ashby, Holder-M.Wishnowsky.") == -1)
}

/// ESPN can post the kick as its own play after a touchdown whose text already ends with
/// it. Either way the kicker gets the point once.
@Test func liveTablePaysAnExtraPointOnce() throws {
    let rules = try liveRules()
    func total(_ texts: [(String, Bool)]) -> Double {
        let plays = texts.map { play($0.0, touchdown: $0.1) }
        let drive = Drive(id: "d", teamID: "17", teamAbbreviation: "", result: "", isScore: true,
                          yards: 0, playCount: plays.count, timeElapsed: "", summary: "",
                          startText: nil, plays: plays, isCurrent: true)
        let detail = GameDetail(gameID: neAtSea.id, drives: [drive], scoringPlayIDs: [])
        return FantasyGameScorer(detail: detail, game: neAtSea).lines(for: borregales)
            .reduce(0) { $0 + rules.points(for: $1.stats, position: .kicker) }
    }
    let kick = ("A.Borregales extra point is GOOD, Center-J.Ashby, Holder-M.Wishnowsky.", false)
    let bare = ("D.Maye pass short left to S.Diggs for 9 yards, TOUCHDOWN.", true)
    let withKick = ("D.Maye pass short left to S.Diggs for 9 yards, TOUCHDOWN. A.Borregales extra point is GOOD, Center-J.Ashby, Holder-M.Wishnowsky.", true)
    #expect(total([bare, kick]) == 1)
    #expect(total([withKick, kick]) == 1)
}

/// Every team-defense value in this table is a slot override on a base of zero.
@Test func liveTablePaysTheDefense() throws {
    #expect(try points(seahawks, on: "(Shotgun) D.Maye sacked at NE 30 for -6 yards (B.Mafe).") == 1)
    #expect(try points(seahawks, on: "D.Maye pass short right intended for S.Diggs INTERCEPTED by D.Williams at SEA 30. D.Williams to SEA 45 for 15 yards (S.Diggs).") == 2)
    #expect(try points(seahawks, on: "D.Maye pass short middle intended for S.Diggs INTERCEPTED by D.Williams at NE 40. D.Williams for 40 yards, TOUCHDOWN. J.Myers extra point is GOOD, Center-C.Stoll, Holder-M.Dickson.",
                       touchdown: true) == 8)
}

/// The play in RedZone before the play feed had it (recorded live, ATL @ NO): scored
/// straight off the scoreboard, Bijan's 9-yard run is worth 0.9.
@Test func liveTableScoresTheScoreboardsLastPlay() throws {
    let json = """
    {"events": [{"id": "401872979", "shortName": "ATL @ NO", "competitions": [{
      "status": {"period": 3, "displayClock": "6:27", "type": {"state": "in", "name": "STATUS_IN_PROGRESS"}},
      "competitors": [
        {"homeAway": "home", "score": "10", "team": {"id": "18", "abbreviation": "NO"}},
        {"homeAway": "away", "score": "24", "team": {"id": "1", "abbreviation": "ATL"}}],
      "situation": {"possession": "1", "down": 2, "distance": 1, "possessionText": "NO 38",
        "lastPlay": {"id": "4018729791234", "type": {"id": "5"},
          "text": "Bi.Robinson left guard to NO 38 for 9 yards (D.Stutsman).",
          "statYardage": 9, "start": {"team": {"id": "1"}}, "end": {"team": {"id": "1"}}}}}]}]}
    """
    let board = try JSONDecoder().decode(ESPNScoreboardDTO.self, from: Data(json.utf8))
    let game = try #require(ESPNMapper.games(from: board).first)
    let play = try #require(game.situation?.lastPlay)
    #expect(play.start.teamID == "1")

    let bijan = rostered(4430807, "Bijan", "Robinson", .runningBack, team: 1)
    let drive = Drive(id: "d", teamID: "1", teamAbbreviation: "ATL", result: "", isScore: false,
                      yards: 0, playCount: 1, timeElapsed: "", summary: "", startText: nil,
                      plays: [play], isCurrent: true)
    let rules = try liveRules()
    let points = FantasyGameScorer(detail: GameDetail(gameID: game.id, drives: [drive], scoringPlayIDs: []),
                                   game: game).lines(for: bijan)
        .reduce(0) { $0 + rules.points(for: $1.stats, position: .runningBack) }
    #expect((points * 100).rounded() / 100 == 0.9)
}
