import Foundation
import FootballCore

/// Where games come from. `ESPNClient` is the real one; `ReplaySource` fakes a live
/// game from a recorded one so the whole app can be exercised midweek.
protocol GameFeed: Sendable {
    func scoreboard() async throws -> ESPNClient.Fetch<[Game]>
    func summary(gameID: String) async throws -> ESPNClient.Fetch<GameDetail>
    func allTeams() async throws -> [ESPNClient.Team]
}

extension ESPNClient: GameFeed {}
