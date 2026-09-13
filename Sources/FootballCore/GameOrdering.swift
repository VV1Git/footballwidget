import Foundation

public enum GameOrdering {

    /// The order the panel lists games in: whatever is being played first, then what is
    /// coming up, then what has finished — with starred teams at the top of each group.
    ///
    /// Kept here rather than in the store so the comparator can be tested. A sort
    /// predicate has to be a strict weak ordering, and getting that wrong does not
    /// throw — Swift just returns the elements in an arbitrary order, which is very
    /// hard to spot by eye on a 16-game slate.
    public static func sorted(_ games: [Game], favorites: Set<String>) -> [Game] {
        games.sorted { isOrdered($0, before: $1, favorites: favorites) }
    }

    static func isOrdered(_ a: Game, before b: Game, favorites: Set<String>) -> Bool {
        let ra = rank(a), rb = rank(b)
        if ra != rb { return ra < rb }

        let fa = isFavorite(a, favorites), fb = isFavorite(b, favorites)
        if fa != fb { return fa }

        // Every pair has to be compared on the same keys in the same order. Falling
        // back to a different key only when two kickoffs happen to be equal makes the
        // ordering intransitive as soon as several games share a kickoff time, which
        // on an NFL Sunday is eight of them at once.
        let ka = a.kickoff ?? .distantFuture
        let kb = b.kickoff ?? .distantFuture
        if ka != kb { return ka < kb }

        return a.shortName < b.shortName
    }

    public static func isFavorite(_ game: Game, _ favorites: Set<String>) -> Bool {
        favorites.contains(game.home.abbreviation) || favorites.contains(game.away.abbreviation)
    }

    /// Live games above upcoming ones above finished ones. Starring a team lifts it
    /// within its group, but never above a game that is actually being played.
    static func rank(_ game: Game) -> Int {
        switch game.phase {
        case .live, .halftime: return 0
        case .pre, .unknown: return 1
        case .final: return 2
        }
    }
}
