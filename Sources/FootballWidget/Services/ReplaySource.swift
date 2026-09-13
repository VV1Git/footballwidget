import Foundation
import FootballCore

/// Replays a finished game as though it were being played right now.
///
/// The NFL plays on Sundays; this exists so the live panel, the ladder filling in
/// play by play, sorting and all three alert types can be exercised on a Wednesday.
/// It pulls a real completed game from ESPN, then reveals it one play at a time.
///
/// Enable with `FootballWidget --replay [secondsPerPlay]`.
actor ReplaySource: GameFeed {

    private let upstream: ESPNClient
    private let secondsPerPlay: Double
    private var started: Date?
    private var template: Game?
    private var fullDetail: GameDetail?
    private var orderedPlays: [(driveIndex: Int, play: Play)] = []
    private var loadFailed = false

    init(upstream: ESPNClient = ESPNClient(), secondsPerPlay: Double = 1.5) {
        self.upstream = upstream
        self.secondsPerPlay = secondsPerPlay
    }

    // MARK: - Feed

    func scoreboard() async throws -> ESPNClient.Fetch<[Game]> {
        try await loadIfNeeded()
        guard let template else { return .updated([]) }
        return .updated([synthesizedGame(from: template)])
    }

    func summary(gameID: String) async throws -> ESPNClient.Fetch<GameDetail> {
        try await loadIfNeeded()
        guard let full = fullDetail else { return .updated(GameDetail(gameID: gameID, drives: [], scoringPlayIDs: [])) }
        return .updated(truncatedDetail(from: full))
    }

    func allTeams() async throws -> [ESPNClient.Team] {
        try await upstream.allTeams()
    }

    // MARK: - Loading

    private func loadIfNeeded() async throws {
        guard template == nil, !loadFailed else { return }

        guard case .updated(let games) = try await upstream.scoreboard() else { return }
        // Prefer a finished game; fall back to whatever has the most complete feed.
        guard let source = games.first(where: { $0.phase == .final }) ?? games.first else {
            loadFailed = true
            return
        }
        guard case .updated(let detail) = try await upstream.summary(gameID: source.id) else {
            loadFailed = true
            return
        }

        // `drives` is newest-first; replay wants oldest-first.
        let chronological = Array(detail.drives.reversed())
        var flattened: [(Int, Play)] = []
        for (i, drive) in chronological.enumerated() {
            for play in drive.plays { flattened.append((i, play)) }
        }

        fullDetail = GameDetail(gameID: source.id, drives: chronological,
                                scoringPlayIDs: detail.scoringPlayIDs)
        orderedPlays = flattened
        template = source
        started = .now
        NSLog("[FootballWidget] replay loaded \(source.shortName): \(flattened.count) plays at \(secondsPerPlay)s each")
    }

    // MARK: - Virtual clock

    private var revealedCount: Int {
        guard let started, !orderedPlays.isEmpty else { return 0 }
        let elapsed = Date.now.timeIntervalSince(started)
        return min(orderedPlays.count, max(1, Int(elapsed / secondsPerPlay) + 1))
    }

    private var currentPlay: Play? {
        let n = revealedCount
        guard n > 0 else { return nil }
        return orderedPlays[n - 1].play
    }

    private func synthesizedGame(from template: Game) -> Game {
        var game = template
        let n = revealedCount
        let finished = n >= orderedPlays.count

        guard let play = currentPlay else {
            game.phase = .pre
            return game
        }

        // The play feed carries running totals, so the newest play that reports a
        // score is the score right now.
        game.home.score = 0
        game.away.score = 0
        for (_, p) in orderedPlays.prefix(n) {
            if let h = p.homeScore, let a = p.awayScore {
                game.home.score = h
                game.away.score = a
            }
        }

        game.phase = finished ? .final : .live
        game.period = play.period
        game.displayClock = play.clock
        game.statusDetail = finished ? "Final" : "\(game.periodLabel) \(play.clock)"

        let spotTeam = play.end.teamID ?? play.start.teamID
        let toEndzone = play.end.yardsToEndzone ?? play.start.yardsToEndzone
        game.situation = finished ? nil : Situation(
            possessionTeamID: spotTeam,
            shortDownDistance: shortDownDistance(play),
            downDistanceText: play.downDistanceText,
            possessionText: ballSpot(play),
            yardLine: play.end.yardLine ?? play.start.yardLine,
            down: play.end.down ?? play.start.down,
            distance: play.end.distance ?? play.start.distance,
            isRedZone: (toEndzone ?? 100) <= 20,
            homeTimeouts: 3,
            awayTimeouts: 3,
            lastPlayText: play.text,
            lastPlayID: play.id,
            lastPlayTypeID: play.typeID,
            lastPlayWasScoring: play.isScoring,
            lastPlayWasTurnover: play.isTurnover
        )
        return game
    }

    /// The live scoreboard reports a spot like "SEA 34"; the play feed only carries it
    /// inside the down-and-distance sentence, so pull it back out.
    private func ballSpot(_ play: Play) -> String? {
        guard let text = play.downDistanceText,
              let range = text.range(of: " at ") else { return nil }
        return String(text[range.upperBound...])
    }

    private func shortDownDistance(_ play: Play) -> String? {
        guard let down = play.end.down ?? play.start.down,
              let distance = play.end.distance ?? play.start.distance,
              down > 0 else { return nil }
        let ordinal = ["", "1st", "2nd", "3rd", "4th"]
        guard down < ordinal.count else { return nil }
        return "\(ordinal[down]) & \(distance)"
    }

    private func truncatedDetail(from full: GameDetail) -> GameDetail {
        let n = revealedCount
        var remaining = n
        var drives: [Drive] = []

        for drive in full.drives {                    // chronological here
            guard remaining > 0 else { break }
            var copy = drive
            if drive.plays.count <= remaining {
                remaining -= drive.plays.count
            } else {
                copy.plays = Array(drive.plays.prefix(remaining))
                copy.isCurrent = true
                copy.result = "In progress"
                remaining = 0
            }
            drives.append(copy)
        }

        // The UI wants newest first.
        return GameDetail(gameID: full.gameID, drives: drives.reversed(),
                          scoringPlayIDs: full.scoringPlayIDs)
    }
}
