import Foundation
import AppKit
import FootballCore

/// Records your league's raw JSON as a test fixture, with the identifying bits removed.
///
/// The fantasy DTOs were written against ESPN's documented v3 shape rather than a
/// recording, because no league credentials were available while building them. Running
/// `FootballWidget --dump-fantasy <file>` once you are connected captures the real
/// thing, so the mapper tests can run against your league instead of a reconstruction.
@MainActor
enum FantasyDump {
    static var requestedPath: String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--dump-fantasy"),
              arguments.count > index + 1 else { return nil }
        return arguments[index + 1]
    }

    static func run(path: String, preferences: Preferences) async {
        let credentials = FantasyClient.Credentials(
            leagueID: preferences.fantasyLeagueIDs.first ?? "",
            espnS2: CredentialStore.read(.espnS2),
            swid: CredentialStore.read(.swid)
        )

        guard !credentials.leagueID.isEmpty else {
            fail("No league connected. Add one in Settings › Fantasy first.")
            return
        }

        do {
            let raw = try await FantasyClient().rawLeagueJSON(credentials: credentials)
            let redacted = redact(raw)
            try redacted.write(to: URL(fileURLWithPath: path))
            print("wrote \(path) (\(redacted.count) bytes, member ids and names redacted)")
        } catch {
            let message = (error as? FantasyClient.FantasyError)?.errorDescription
                ?? error.localizedDescription
            fail(message)
        }
        NSApp.terminate(nil)
    }

    /// Replaces the SWIDs and member names with stable placeholders.
    ///
    /// SWIDs are rewritten consistently rather than blanked, because `teams[].owners`
    /// has to keep pointing at the right member for the fixture to exercise the
    /// "which team is mine" logic at all.
    static func redact(_ data: Data) -> Data {
        guard var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return data }

        var replacements: [String: String] = [:]
        if var members = root["members"] as? [[String: Any]] {
            for (index, member) in members.enumerated() {
                if let id = member["id"] as? String {
                    let placeholder = String(format: "{%04d-0000-0000-0000-000000000000}", index + 1)
                    replacements[id] = placeholder
                    members[index]["id"] = placeholder
                }
                members[index]["displayName"] = "member\(index + 1)"
                members[index]["firstName"] = "Member"
                members[index]["lastName"] = "\(index + 1)"
            }
            root["members"] = members
        }

        if var teams = root["teams"] as? [[String: Any]] {
            for (index, team) in teams.enumerated() {
                if let owners = team["owners"] as? [String] {
                    teams[index]["owners"] = owners.map { replacements[$0] ?? $0 }
                }
            }
            root["teams"] = teams
        }

        return (try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]))
            ?? data
    }

    private static func fail(_ message: String) {
        FileHandle.standardError.write(Data("dump-fantasy: \(message)\n".utf8))
        NSApp.terminate(nil)
    }
}
