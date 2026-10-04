import Foundation

/// Fantasy points per play, kept per league and per game, for the field map's chips.
///
/// Every play is scored from its own text, so this is only ever a cache of what the
/// latest feed works out to: a game's figures are replaced wholesale each time its feed
/// is scored again, which is also how a corrected play's chip changes. Leagues are kept
/// apart because they score differently, and a player rostered in two leagues is worth
/// what each of them says.
public struct FantasyLedger: Sendable, Equatable {
    /// league id → game id → play id → player id → points.
    public private(set) var byLeague: [String: [String: [String: [Int: Double]]]]

    public init(byLeague: [String: [String: [String: [Int: Double]]]] = [:]) {
        self.byLeague = byLeague
    }

    public var isEmpty: Bool { byLeague.values.allSatisfy { $0.values.allSatisfy(\.isEmpty) } }

    /// Replaces what one league has for one game. `plays` is play id → player id →
    /// points, holding only the plays that were worth something.
    public mutating func replace(game: String, league: String, with plays: [String: [Int: Double]]) {
        byLeague[league, default: [:]][game] = plays.isEmpty ? nil : plays
    }

    public func points(league: String, game: String, play: String, player: Int) -> Double? {
        byLeague[league]?[game]?[play]?[player]
    }

    /// Play id → player id → points, for one league's view of one game. A player's chip
    /// reads his points from one league only: two leagues scoring differently must not
    /// lend each other figures.
    public func plays(league: String, game: String) -> [String: [Int: Double]] {
        byLeague[league]?[game] ?? [:]
    }

    public mutating func removeLeague(_ id: String) {
        byLeague[id] = nil
    }

    /// Drops every game not in `ids` — the slate has moved on and its play ids with it.
    public mutating func retainGames(_ ids: Set<String>) {
        for league in byLeague.keys {
            byLeague[league] = byLeague[league]?.filter { ids.contains($0.key) }
        }
    }
}

/// The alerts already delivered this session, so none goes out twice.
///
/// Bounded, oldest forgotten first. It used to be a set emptied wholesale at 500, and an
/// alert from just before the purge could then go out again if ESPN's cache served an
/// older scoreboard and the newer one came back.
public struct DeliveredLog: Sendable {
    public let capacity: Int
    private var order: [String] = []
    private var members: Set<String> = []

    public init(capacity: Int = 2000) {
        self.capacity = capacity
    }

    /// True when `id` had not been delivered and is now recorded as delivered.
    public mutating func insert(_ id: String) -> Bool {
        guard members.insert(id).inserted else { return false }
        order.append(id)
        if order.count > capacity {
            members.remove(order.removeFirst())
        }
        return true
    }

    public func contains(_ id: String) -> Bool { members.contains(id) }
}
