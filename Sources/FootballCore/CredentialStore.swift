import Foundation

/// Stores the two ESPN cookies in a file only your user account can read.
///
/// These lived in the Keychain, which is the textbook answer and was the wrong one
/// here. macOS ties a keychain item's ACL to the code signature of the app that
/// created it, and an ad-hoc signed app — which is what `Scripts/build_app.sh`
/// produces, since there is no developer account — gets a brand new signature every
/// time it is rebuilt. The moment the signature changes the ACL no longer matches, and
/// every single read pops the "enter your login keychain password" dialog. Caching the
/// reads only reduced that to once per launch; rebuilding brought it straight back.
///
/// So: a JSON file at `~/Library/Application Support/FootballWidget/credentials.json`,
/// created `0600` inside a `0700` directory. That is the same protection level as the
/// app's own preferences — readable by processes running as you, by nobody else — and
/// it never prompts. The trade is real but small for a pair of ESPN session cookies,
/// and it is written down here rather than being a silent downgrade.
public enum CredentialStore {

    public enum Key: String, CaseIterable, Codable, Sendable {
        case espnS2 = "espn_s2"
        case swid = "SWID"
    }

    private struct Stored: Codable {
        var espnS2: String?
        var swid: String?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: Stored?

    // MARK: - Location

    /// Overridable so tests do not write into the real Application Support directory.
    nonisolated(unsafe) public static var overrideDirectory: URL?

    public static var directoryURL: URL {
        if let overrideDirectory { return overrideDirectory }
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support")
        return base.appending(path: "FootballWidget")
    }

    public static var fileURL: URL { directoryURL.appending(path: "credentials.json") }

    // MARK: - Reading

    public static func read(_ key: Key) -> String? {
        let stored = load()
        let value: String?
        switch key {
        case .espnS2: value = stored.espnS2
        case .swid: value = stored.swid
        }
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func load() -> Stored {
        lock.lock()
        defer { lock.unlock() }
        if let cache { return cache }

        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(Stored.self, from: data)
        else {
            cache = Stored()
            return Stored()
        }
        cache = decoded
        return decoded
    }

    // MARK: - Writing

    @discardableResult
    public static func write(_ value: String, for key: Key) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)

        lock.lock()
        var stored = cache ?? (try? JSONDecoder().decode(
            Stored.self, from: (try? Data(contentsOf: fileURL)) ?? Data()
        )) ?? Stored()

        switch key {
        case .espnS2: stored.espnS2 = trimmed.isEmpty ? nil : trimmed
        case .swid: stored.swid = trimmed.isEmpty ? nil : trimmed
        }
        cache = stored
        lock.unlock()

        return persist(stored)
    }

    @discardableResult
    public static func delete(_ key: Key) -> Bool {
        write("", for: key)
    }

    public static func deleteAll() {
        lock.lock()
        cache = Stored()
        lock.unlock()
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static func persist(_ stored: Stored) -> Bool {
        let manager = FileManager.default
        do {
            if !manager.fileExists(atPath: directoryURL.path) {
                try manager.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            let data = try JSONEncoder().encode(stored)
            // Write, then tighten the permissions before anything else can open it.
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return true
        } catch {
            NSLog("[FootballWidget] could not save credentials: \(error.localizedDescription)")
            return false
        }
    }

    /// Forces the next read to hit disk again.
    public static func invalidateCache() {
        lock.lock()
        cache = nil
        lock.unlock()
    }
}
