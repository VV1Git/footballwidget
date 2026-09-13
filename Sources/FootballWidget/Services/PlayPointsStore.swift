import Foundation
import FootballCore

/// Remembers which play earned which player their fantasy points, across launches.
///
/// ESPN reports running totals, never per-play points, so the only way to know what a
/// play was worth is to watch a player's total move and pin the difference on the play
/// that named them. That knowledge is built up as the app runs — which meant every
/// relaunch threw it away and the field map lost all its points chips until something
/// else scored. Keeping it on disk makes the chips survive a restart.
///
/// Entries are dropped after a couple of days; play ids belong to a single game and are
/// no use once the week has moved on.
enum PlayPointsStore {
    private struct Stored: Codable {
        var savedAt: Date
        /// play id → player id (as a string, since JSON keys must be) → points.
        var points: [String: [String: Double]]
    }

    private static var fileURL: URL {
        CredentialStore.directoryURL.appending(path: "play-points.json")
    }

    private static let maximumAge: TimeInterval = 60 * 60 * 24 * 3

    static func load() -> [String: [Int: Double]] {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              Date.now.timeIntervalSince(stored.savedAt) < maximumAge
        else { return [:] }

        var result: [String: [Int: Double]] = [:]
        for (playID, byPlayer) in stored.points {
            var converted: [Int: Double] = [:]
            for (playerID, points) in byPlayer {
                if let id = Int(playerID) { converted[id] = points }
            }
            if !converted.isEmpty { result[playID] = converted }
        }
        return result
    }

    static func save(_ points: [String: [Int: Double]]) {
        var encoded: [String: [String: Double]] = [:]
        for (playID, byPlayer) in points {
            var converted: [String: Double] = [:]
            for (playerID, value) in byPlayer { converted[String(playerID)] = value }
            encoded[playID] = converted
        }

        let stored = Stored(savedAt: .now, points: encoded)
        do {
            let directory = CredentialStore.directoryURL
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            try JSONEncoder().encode(stored).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("[FootballWidget] could not save play points: \(error.localizedDescription)")
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
