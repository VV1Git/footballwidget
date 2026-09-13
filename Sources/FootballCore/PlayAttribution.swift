import Foundation

/// Works out which rostered players a play involved, so the field map can show what a
/// play was worth to your lineup.
///
/// ESPN's play feed carries no per-player breakdown — plays have `teamParticipants`
/// but no `participants` array — so involvement is read out of the play text, which
/// names players as first-initial-dot-surname ("S.Darnold", "J.Smith-Njigba").
///
/// Points are never recomputed here. ESPN stays the source of truth: when a player's
/// `appliedStatTotal` moves between polls, that delta is attributed to the most recent
/// play naming them. Where that is ambiguous the attribution is dropped rather than
/// guessed.
public enum PlayAttribution {

    /// A rostered player the play named, and what it was worth if we know.
    public struct Credit: Hashable, Sendable {
        public var playerID: Int
        public var playerName: String
        public var isMine: Bool
        public var position: FantasyPosition
        /// Nil when the player was named but no scoring delta has been tied to the play
        /// — a tackler, a blocker, or points that have not landed yet.
        public var points: Double?

        public init(playerID: Int, playerName: String, isMine: Bool,
                    position: FantasyPosition, points: Double?) {
            self.playerID = playerID
            self.playerName = playerName
            self.isMine = isMine
            self.position = position
            self.points = points
        }
    }

    // MARK: - Name parsing

    /// Matches "S.Darnold" and "J.Smith-Njigba", apostrophes and hyphens included.
    /// `NSRegularExpression` is thread-safe once built, so one instance is reused
    /// rather than recompiling the pattern for each of a game's ~180 plays.
    nonisolated(unsafe) private static let nameToken = try! NSRegularExpression(
        pattern: "\\b([A-Z])\\.([A-Z][A-Za-z'\\-]+)"
    )

    /// Every `F.Lastname` token in a play description, in order of appearance.
    public static func names(in text: String) -> [(initial: Character, surname: String)] {
        let range = NSRange(text.startIndex..., in: text)
        return nameToken.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges >= 3,
                  let initialRange = Range(match.range(at: 1), in: text),
                  let surnameRange = Range(match.range(at: 2), in: text),
                  let initial = text[initialRange].first
            else { return nil }
            return (initial, String(text[surnameRange]))
        }
    }

    // MARK: - Matching

    /// Rostered players named by a play.
    ///
    /// `candidates` should already be narrowed to the players whose NFL team is in this
    /// game, which keeps "J.Chase" competing against a handful of names rather than the
    /// whole league. A surname that matches more than one candidate is skipped — being
    /// silent beats crediting the wrong player.
    public static func players(
        namedIn text: String,
        candidates: [(player: RosterPlayer, isMine: Bool)]
    ) -> [(player: RosterPlayer, isMine: Bool)] {
        guard !candidates.isEmpty, !text.isEmpty else { return [] }
        let tokens = names(in: text)
        guard !tokens.isEmpty else { return [] }

        var found: [(player: RosterPlayer, isMine: Bool)] = []
        var seen = Set<Int>()

        for token in tokens {
            let hits = candidates.filter { entry in
                Self.matches(player: entry.player, initial: token.initial, surname: token.surname)
            }
            // Ambiguous: two rostered players share an initial and surname on the same
            // team. Rare, and not worth a wrong answer.
            guard hits.count == 1, let match = hits.first else { continue }
            guard seen.insert(match.player.id).inserted else { continue }
            found.append(match)
        }
        return found
    }

    static func matches(player: RosterPlayer, initial: Character, surname: String) -> Bool {
        guard let playerInitial = player.firstName.first else { return false }
        guard String(playerInitial).caseInsensitiveCompare(String(initial)) == .orderedSame
        else { return false }
        return normalize(player.lastName) == normalize(surname)
    }

    /// ESPN is inconsistent about punctuation between feeds ("Smith-Njigba" vs
    /// "SmithNjigba", "Ja'Marr" vs "JaMarr"), so compare on letters alone.
    static func normalize(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter }
    }

    // MARK: - Crediting

    /// Attaches known point deltas to the players a play named.
    ///
    /// `deltas` maps player id to points gained since the last poll. A player named by
    /// the play but absent from `deltas` still returns a credit with `points == nil`,
    /// which is how the field map shows "your guy was involved" without inventing a
    /// number.
    public static func credits(
        forPlayText text: String,
        candidates: [(player: RosterPlayer, isMine: Bool)],
        deltas: [Int: Double]
    ) -> [Credit] {
        players(namedIn: text, candidates: candidates).map { entry in
            Credit(
                playerID: entry.player.id,
                playerName: entry.player.fullName,
                isMine: entry.isMine,
                position: entry.player.position,
                points: deltas[entry.player.id]
            )
        }
    }

    /// Point deltas between two polls, keyed by player id.
    ///
    /// Downward revisions are kept — ESPN issues stat corrections — but callers should
    /// not raise notifications for them.
    public static func deltas(
        previous: [Int: Double],
        current: [Int: Double]
    ) -> [Int: Double] {
        var result: [Int: Double] = [:]
        for (id, points) in current {
            guard let before = previous[id] else { continue }   // first sighting: silent
            // Fantasy scoring is two decimal places, but subtracting doubles is not:
            // 16.4 - 10.0 comes out as 6.399999999999999, which would both display
            // wrong and sit just under a 6.0 alert threshold.
            let delta = ((points - before) * 100).rounded() / 100
            if abs(delta) >= 0.01 { result[id] = delta }
        }
        return result
    }

    /// The newest play in a game whose text names this player.
    ///
    /// Drives arrive newest-first and plays within a drive run oldest-first, so the
    /// search walks drives forward and plays backward to find the most recent mention.
    public static func mostRecentPlay(
        naming player: RosterPlayer,
        in detail: GameDetail
    ) -> Play? {
        let candidate: [(player: RosterPlayer, isMine: Bool)] = [(player, true)]
        for drive in detail.drives {
            for play in drive.plays.reversed() where play.kind != .administrative {
                if !players(namedIn: play.text, candidates: candidate).isEmpty {
                    return play
                }
            }
        }
        return nil
    }

    /// Flattens a matchup into the id → points map the diffing works on.
    public static func pointsByPlayer(_ matchup: FantasyMatchup) -> [Int: Double] {
        var result: [Int: Double] = [:]
        for entry in matchup.allPlayers { result[entry.player.id] = entry.player.points }
        return result
    }
}
