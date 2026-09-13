import Foundation
import Testing
@testable import FootballCore

/// Serialized: the store is a global with a process-wide cache, so these cannot run
/// in parallel with each other without reading one another's files.
@Suite(.serialized)
struct CredentialStoreTests {

    /// Each test gets its own directory so nothing touches the real one.
    private func withScratchStore(_ body: () throws -> Void) rethrows {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "fwcreds-\(UUID().uuidString)")
        CredentialStore.overrideDirectory = scratch
        CredentialStore.invalidateCache()
        defer {
            try? FileManager.default.removeItem(at: scratch)
            CredentialStore.overrideDirectory = nil
            CredentialStore.invalidateCache()
        }
        try body()
    }

    @Test func storesAndReadsBackBothCookies() throws {
        try withScratchStore {
            #expect(CredentialStore.read(.espnS2) == nil)

            #expect(CredentialStore.write("AEBabc%2Fdef", for: .espnS2))
            #expect(CredentialStore.write("{SW-1234}", for: .swid))

            #expect(CredentialStore.read(.espnS2) == "AEBabc%2Fdef")
            #expect(CredentialStore.read(.swid) == "{SW-1234}")
        }
    }

    /// Writing one must not wipe the other — they are saved to the same file.
    @Test func writingOneCookieKeepsTheOther() throws {
        try withScratchStore {
            CredentialStore.write("first", for: .espnS2)
            CredentialStore.write("{SW}", for: .swid)
            CredentialStore.write("second", for: .espnS2)

            #expect(CredentialStore.read(.espnS2) == "second")
            #expect(CredentialStore.read(.swid) == "{SW}")
        }
    }

    /// The whole point of the change: values must still be there on the next launch, with
    /// no prompt and no dependence on the app's code signature.
    @Test func survivesACacheDropAsANewLaunchWould() throws {
        try withScratchStore {
            CredentialStore.write("persisted", for: .espnS2)
            CredentialStore.invalidateCache()
            #expect(CredentialStore.read(.espnS2) == "persisted")
        }
    }

    @Test func storedFileIsReadableOnlyByTheOwner() throws {
        try withScratchStore {
            CredentialStore.write("secret", for: .espnS2)

            let attributes = try FileManager.default.attributesOfItem(
                atPath: CredentialStore.fileURL.path)
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            #expect(mode == 0o600, "file mode was \(String(mode, radix: 8))")

            let directory = try FileManager.default.attributesOfItem(
                atPath: CredentialStore.directoryURL.path)
            let directoryMode = (directory[.posixPermissions] as? NSNumber)?.intValue ?? 0
            #expect(directoryMode == 0o700, "directory mode was \(String(directoryMode, radix: 8))")
        }
    }

    @Test func emptyOrBlankValuesClearTheEntry() throws {
        try withScratchStore {
            CredentialStore.write("value", for: .espnS2)
            CredentialStore.write("   ", for: .espnS2)
            #expect(CredentialStore.read(.espnS2) == nil)

            CredentialStore.write("value", for: .swid)
            CredentialStore.delete(.swid)
            #expect(CredentialStore.read(.swid) == nil)
        }
    }

    @Test func trimsWhitespaceOffPastedValues() throws {
        try withScratchStore {
            CredentialStore.write("  AEBabc\n", for: .espnS2)
            #expect(CredentialStore.read(.espnS2) == "AEBabc")
        }
    }

    @Test func readingWithNoFileYetIsSimplyEmpty() throws {
        try withScratchStore {
            #expect(CredentialStore.read(.espnS2) == nil)
            #expect(CredentialStore.read(.swid) == nil)
        }
    }

    @Test func deleteAllRemovesTheFile() throws {
        try withScratchStore {
            CredentialStore.write("a", for: .espnS2)
            #expect(FileManager.default.fileExists(atPath: CredentialStore.fileURL.path))
            CredentialStore.deleteAll()
            #expect(!FileManager.default.fileExists(atPath: CredentialStore.fileURL.path))
            #expect(CredentialStore.read(.espnS2) == nil)
        }
    }
}
