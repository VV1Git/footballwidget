import Foundation

public enum GameSectionKind: String, Sendable, Hashable {
    case today, week
}

public struct GameSection: Identifiable, Sendable, Hashable {
    public var kind: GameSectionKind
    public var games: [Game]

    public var id: String { kind.rawValue }

    public var title: String {
        switch kind {
        case .today: return "Today"
        case .week: return "This week"
        }
    }

    /// "1 game" / "15 games", for the collapsed header.
    public var countLabel: String {
        games.count == 1 ? "1 game" : "\(games.count) games"
    }

    public var liveCount: Int { games.filter(\.isLive).count }
}

public enum GameSections {

    /// Splits the slate into what is happening today and what is coming later.
    ///
    /// Anything being played counts as today whatever its listed kickoff, so a game
    /// that has run past midnight locally never falls out of the section you are
    /// watching it in. Empty sections are dropped rather than shown as empty headers.
    public static func build(
        _ games: [Game],
        favorites: Set<String> = [],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [GameSection] {
        let ordered = GameOrdering.sorted(games, favorites: favorites)

        var today: [Game] = []
        var week: [Game] = []

        for game in ordered {
            if game.isLive {
                today.append(game)
            } else if let kickoff = game.kickoff, calendar.isDate(kickoff, inSameDayAs: now) {
                today.append(game)
            } else {
                week.append(game)
            }
        }

        var sections: [GameSection] = []
        if !today.isEmpty { sections.append(GameSection(kind: .today, games: today)) }
        if !week.isEmpty { sections.append(GameSection(kind: .week, games: week)) }
        return sections
    }
}
