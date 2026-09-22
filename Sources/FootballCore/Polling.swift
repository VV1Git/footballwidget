import Foundation

/// Stops the same play feed being fetched twice at once.
///
/// Several callers ask for a game's play feed on their own schedule: the store's poll
/// loop, the torn-off window's loop, and opening a game (which fetches straight away so
/// the ladder is not empty). They overlap. Opening a game used to pull the ~500 KB feed
/// twice in the same instant, and a pinned game was fetched by both loops every five
/// seconds. ESPN sends no ETag on these endpoints, so neither copy was ever a cheap
/// 304; each one was a full download, decode and republish.
///
/// A fetch is skipped while one for the same game is still in flight, or when one
/// started within `freshness` — which is kept below the fastest poll interval, so a
/// loop that is due always gets its fetch.
public struct FetchGate: Sendable {
    public let freshness: TimeInterval
    private var inFlight: Set<String> = []
    private var lastStarted: [String: Date] = [:]

    public init(freshness: TimeInterval) {
        self.freshness = freshness
    }

    /// Claims a fetch for `id`. Returns false when the caller should skip it; a caller
    /// that gets true must call `end(_:)` when the fetch finishes, however it finishes.
    public mutating func begin(_ id: String, now: Date = .now) -> Bool {
        guard !inFlight.contains(id) else { return false }
        if let last = lastStarted[id], now.timeIntervalSince(last) < freshness { return false }
        inFlight.insert(id)
        lastStarted[id] = now
        return true
    }

    /// Claims a follow-up fetch for a feed that came back a play short of the scoreboard.
    ///
    /// Not held to `freshness`, because being a second or two after the last fetch is the
    /// point, and it leaves `lastStarted` alone. That keeps the guarantee above intact:
    /// the poll loop's own fetch is judged against the last *poll* fetch, so a burst of
    /// retries can never make a due poll skip its turn.
    public mutating func beginRetry(_ id: String) -> Bool {
        guard !inFlight.contains(id) else { return false }
        inFlight.insert(id)
        return true
    }

    public mutating func end(_ id: String) {
        inFlight.remove(id)
    }

    public func isInFlight(_ id: String) -> Bool { inFlight.contains(id) }

    /// When a fetch for `id` last started, whether or not it succeeded.
    public func lastStarted(_ id: String) -> Date? { lastStarted[id] }
}

/// Whether a game's play feed is worth fetching for the fantasy layer, when nobody is
/// looking at that game.
///
/// Those feeds are only there so a points change can be pinned on the play that caused
/// it, which needs the feed to contain the newest play — nothing more. The scoreboard,
/// fetched every poll anyway, names each game's latest play, and its ids are the play
/// feed's ids. So a tracked game's ~500 KB feed is fetched when the scoreboard reports a
/// play the held feed does not have yet, and otherwise only once `maxAge` has passed, to
/// pick up ESPN's after-the-fact edits (drive results, corrected play text).
///
/// Before, every tracked game's feed was downloaded, decoded and mapped on every poll.
/// With two leagues that is most of a Sunday slate, every five to twenty seconds, for a
/// feed that had not changed in five polls out of six.
public enum TrackedFeedPolicy {
    public static func shouldFetch(
        latestPlayID: String?,
        held: GameDetail?,
        lastFetched: Date?,
        maxAge: TimeInterval,
        now: Date = .now
    ) -> Bool {
        guard let held, let lastFetched else { return true }
        if now.timeIntervalSince(lastFetched) >= maxAge { return true }
        guard let latestPlayID, !latestPlayID.isEmpty else { return false }
        // The scoreboard can be ahead of the play feed by a few seconds; until the feed
        // catches up, this keeps asking.
        return !held.containsPlay(id: latestPlayID)
    }

    /// The scoreboard names a newest play that the held feed does not carry yet.
    ///
    /// Notifications are cut from the scoreboard, so they arrive the moment it moves; the
    /// ladder and field map are drawn from the play feed, which trails it. Waiting for
    /// the next poll to look again made every play show up a whole interval late — five
    /// seconds with a game open — so a feed in this state is worth asking about again
    /// well before then.
    public static func isBehind(latestPlayID: String?, held: GameDetail?) -> Bool {
        guard let latestPlayID, !latestPlayID.isEmpty else { return false }
        guard let held else { return true }
        return !held.containsPlay(id: latestPlayID)
    }
}

public extension GameDetail {
    func containsPlay(id: String) -> Bool {
        // Newest drives come first and a new play is almost always in the first one.
        drives.contains { drive in drive.plays.contains { $0.id == id } }
    }
}

/// Recognises a response body identical to the last one seen for the same URL.
///
/// ESPN's site API sends no `ETag` or `Last-Modified`, so a conditional request can
/// never come back 304 and every poll is a full body. Many of those bodies are
/// byte-for-byte what the previous poll returned (the CDN caches them for a few
/// seconds). Fingerprinting the bytes lets the client report "unchanged" without
/// decoding and mapping a play feed that decodes in ~10ms.
public struct BodyFingerprints: Sendable {
    private var seen: [String: Int] = [:]

    public init() {}

    public func matches(_ fingerprint: Int, for key: String) -> Bool {
        seen[key] == fingerprint
    }

    /// Call once the body has been decoded successfully, so a body that failed to
    /// decode is not later waved through as "unchanged".
    public mutating func remember(_ fingerprint: Int, for key: String) {
        seen[key] = fingerprint
    }

    /// Hashes every byte. `Data.hashValue` is no use here: it only looks at the first
    /// few dozen bytes, which are the same in every play feed.
    public static func fingerprint(_ data: Data) -> Int {
        var hasher = Hasher()
        hasher.combine(data.count)
        data.withUnsafeBytes { hasher.combine(bytes: $0) }
        return hasher.finalize()
    }
}

/// When the next poll is due.
public enum PollSchedule {

    /// Seconds to wait before polling again, given when the last poll finished and the
    /// interval that applies now.
    ///
    /// Measured from the last poll rather than from "now" so that changing what is on
    /// screen reschedules the loop instead of forcing a fetch. Opening the panel three
    /// seconds after a poll waits the remaining seven of the ten-second open-panel
    /// interval; opening it after a minute closed polls straight away. Before, every
    /// open, close and click into a game cancelled whatever fetch was in flight and
    /// started a new one — a quick open and close cost two full refreshes.
    public static func delay(lastPoll: Date?, interval: TimeInterval, now: Date = .now) -> TimeInterval {
        guard let lastPoll else { return 0 }
        return max(0, interval - now.timeIntervalSince(lastPoll))
    }
}
