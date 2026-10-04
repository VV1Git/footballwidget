import Foundation

/// Works out which rostered players a play involved, and the name rules everything that
/// reads players out of play text shares.
///
/// ESPN's play feed carries no per-player breakdown — plays have `teamParticipants`
/// but no `participants` array — so involvement is read out of the play text, which
/// names players as first-initial-dot-surname ("S.Darnold", "J.Smith-Njigba"). What a
/// play was worth is worked out by `FantasyGameScorer`; this only says who was there.
/// Where a name is ambiguous it is dropped rather than guessed.
public enum PlayAttribution {

    /// A rostered player the play named, and what it was worth if we know.
    public struct Credit: Hashable, Sendable {
        public var playerID: Int
        public var playerName: String
        public var isMine: Bool
        public var position: FantasyPosition
        /// Nil when the player was named but the play earned him nothing — a tackler, a
        /// blocker, an incompletion thrown his way.
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

    /// Matches "S.Darnold" and "J.Smith-Njigba", apostrophes and hyphens included, and
    /// the longer forms ESPN uses to tell players apart — "Bi.Robinson" for Bijan,
    /// "A.St. Brown", "G.Van Roten" — the same shapes `PlaySummary` reads.
    /// `NSRegularExpression` is thread-safe once built, so one instance is reused rather
    /// than recompiling the pattern for each of a game's ~180 plays.
    nonisolated(unsafe) private static let nameToken = try! NSRegularExpression(
        pattern: "\\b([A-Z][a-z]{0,2})\\.((?:St\\. |Van )?[A-Z][A-Za-z'\\-]+)"
    )

    /// Every `F.Lastname` token in a play description, in order of appearance.
    public static func names(in text: String) -> [(initial: String, surname: String)] {
        let range = NSRange(text.startIndex..., in: text)
        return nameToken.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges >= 3,
                  let initialRange = Range(match.range(at: 1), in: text),
                  let surnameRange = Range(match.range(at: 2), in: text)
            else { return nil }
            return (String(text[initialRange]), String(text[surnameRange]))
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

    static func matches(player: RosterPlayer, initial: String, surname: String) -> Bool {
        guard !initial.isEmpty,
              player.firstName.lowercased().hasPrefix(initial.lowercased())
        else { return false }
        return normalize(baseSurname(player.lastName)) == normalize(surname)
    }

    /// A surname as play text writes it. ESPN's fantasy rosters keep the generational
    /// suffix — "Cook III", "Thomas Jr.", "Godwin Jr." — and play text never does
    /// ("J.Cook"), so those players were never found in a single play.
    public static func baseSurname(_ lastName: String) -> String {
        var words = lastName.split(separator: " ").map(String.init)
        let suffixes: Set<String> = ["jr", "jr.", "sr", "sr.", "ii", "iii", "iv", "v"]
        while words.count > 1, let last = words.last, suffixes.contains(last.lowercased()) {
            words.removeLast()
        }
        return words.joined(separator: " ")
    }

    /// ESPN is inconsistent about punctuation between feeds ("Smith-Njigba" vs
    /// "SmithNjigba", "Ja'Marr" vs "JaMarr"), so compare on letters alone.
    static func normalize(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter }
    }

    // MARK: - Crediting

    /// Attaches known points to the players a play named.
    ///
    /// `deltas` maps player id to what the play was worth to him. A player named by the
    /// play but absent from `deltas` still returns a credit with `points == nil`, which
    /// is how the field map shows "your guy was involved" without inventing a number.
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
}
