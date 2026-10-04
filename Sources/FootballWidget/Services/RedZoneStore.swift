import Foundation
import Observation
import FootballCore

/// What the RedZone window shows: which game is featured and why, and the key moments
/// from across the slate.
///
/// Fed by every scoreboard poll whether or not the window is up, so the feed is already
/// warm when it appears. Only what the window draws is observable, and each value is
/// assigned only when it changes, so a clock ticking in some other game redraws nothing.
@MainActor
@Observable
final class RedZoneStore {
    private(set) var spotlightID: String?
    private(set) var spotlightReason = ""
    /// The last few minutes of moments only. The feed keeps more, but the window is for
    /// what just happened: a touchdown from a quarter ago, left at the top of the list
    /// through a quiet stretch, read as if it were news.
    private(set) var moments: [Moment] = []
    /// A game the user chose to watch. It stays featured until they go back to automatic
    /// or it ends.
    private(set) var pickedID: String?

    @ObservationIgnored private var feed = MomentFeed()
    @ObservationIgnored private(set) var ranked: [RankedGame] = []
    /// What the ranker would show, kept apart from a pick so its switching margin is
    /// measured against its own choice and automatic mode resumes where it would be.
    @ObservationIgnored private var autoID: String?
    /// When the ranker's choice last changed, for the minimum dwell.
    @ObservationIgnored private var autoSince: Date?
    /// Game id → its newest snap and when the scoreboard first showed it. Clock events
    /// (timeouts, the two-minute warning) are not snaps. A game's first sighting is dated
    /// long ago, so launching never makes every game look like it just snapped.
    @ObservationIgnored private var lastSnap: [String: (playID: String, at: Date)] = [:]
    @ObservationIgnored private var games: [Game] = []
    @ObservationIgnored weak var fantasy: FantasyStore?
    @ObservationIgnored private let preferences: Preferences
    /// Keeps a game that just ended featured for a couple of minutes when nothing else is
    /// on, rather than the window vanishing on the final whistle.
    @ObservationIgnored private var linger: Task<Void, Never>?

    static let lingerAfterFinal: Duration = .seconds(120)
    static let momentLifetime: TimeInterval = 10 * 60

    init(preferences: Preferences = .shared) {
        self.preferences = preferences
    }

    var isPicked: Bool { pickedID != nil }

    /// Features `gameID` until `pick(nil)` hands the choice back to the ranker.
    func pick(_ gameID: String?) {
        if pickedID != gameID { pickedID = gameID }
        publish()
    }

    /// `changed` is false for a poll that came back identical: it still ages the
    /// "just scored" bonus and keeps the feed's gap clock honest.
    func ingest(_ games: [Game], changed: Bool, now: Date = .now) {
        self.games = games
        if changed {
            feed.ingest(games, now: now)
        } else {
            feed.scoreboardUnchanged(now: now)
        }
        // Re-filtered on every poll, changed or not, so old moments drop off on time.
        let recent = feed.moments.filter { now.timeIntervalSince($0.at) <= Self.momentLifetime }
        if recent != moments { moments = recent }
        noteSnaps(games, now: now)

        ranked = games.compactMap { game in
            let leverage = fantasy.map {
                FantasyLeverage(players: $0.players(inGame: game), game: game)
            } ?? .none
            let snapAge = lastSnap[game.id].map { now.timeIntervalSince($0.at) }
            return RedZoneRanker.rank(game, leverage: leverage,
                                      recent: feed.latest(gameID: game.id),
                                      lastSnapAge: snapAge, now: now)
        }
        let favorites = preferences.favorites
        let favoriteIDs = Set(games.filter { GameOrdering.isFavorite($0, favorites) }.map(\.id))
        let next = RedZoneRanker.spotlight(ranked, current: autoID, favoriteGameIDs: favoriteIDs,
                                           heldFor: autoSince.map { now.timeIntervalSince($0) })
        if next != autoID {
            autoID = next
            autoSince = now
        }
        publish()
    }

    private func noteSnaps(_ games: [Game], now: Date) {
        var seen: [String: (playID: String, at: Date)] = [:]
        for game in games {
            guard let situation = game.situation, let playID = situation.lastPlayID, !playID.isEmpty
            else {
                if let previous = lastSnap[game.id] { seen[game.id] = previous }
                continue
            }
            if let previous = lastSnap[game.id] {
                let isSnap = !FieldGeometry.administrativeTypeIDs.contains(situation.lastPlayTypeID ?? "")
                seen[game.id] = previous.playID != playID && isSnap ? (playID, now) : previous
            } else {
                seen[game.id] = (playID, .distantPast)
            }
        }
        lastSnap = seen
    }

    private func publish() {
        // A pick lasts as long as its game does.
        if let picked = pickedID, !games.contains(where: { $0.id == picked && $0.isLive }) {
            pickedID = nil
        }
        var next = pickedID ?? autoID
        var reason = ranked.first { $0.id == next }?.reason ?? ""

        if next != nil {
            linger?.cancel()
            linger = nil
        } else if let current = spotlightID {
            // Nothing live any more. Hold the game that just finished for a moment.
            next = current
            reason = "Final"
            if linger == nil {
                linger = Task { [weak self] in
                    try? await Task.sleep(for: Self.lingerAfterFinal)
                    guard !Task.isCancelled else { return }
                    self?.endLinger()
                }
            }
        }

        if next != spotlightID { spotlightID = next }
        if reason != spotlightReason { spotlightReason = reason }
    }

    private func endLinger() {
        linger = nil
        guard ranked.isEmpty else { return }
        spotlightID = nil
        spotlightReason = ""
    }
}
