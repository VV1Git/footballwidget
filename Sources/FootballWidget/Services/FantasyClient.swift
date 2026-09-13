import Foundation
import FootballCore

/// Reads one ESPN fantasy league.
///
/// Private leagues need the `espn_s2` and `SWID` cookies from a signed-in browser
/// session; public leagues need neither. The two failure modes are told apart on
/// purpose — a 401 means "this league is private, give me cookies" and a 404 means
/// "there is no such league" — because they need completely different fixes.
actor FantasyClient {

    struct Credentials: Sendable, Equatable {
        var leagueID: String
        var espnS2: String?
        var swid: String?

        var hasCookies: Bool {
            !(espnS2 ?? "").isEmpty && !(swid ?? "").isEmpty
        }
    }

    enum FantasyError: LocalizedError, Equatable {
        case noLeagueConfigured
        case privateLeague
        case credentialsRejected
        case leagueNotFound
        case noTeamForSWID
        case status(Int)
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .noLeagueConfigured:
                return "No league connected yet."
            case .privateLeague:
                return "This league is private. Add your espn_s2 and SWID cookies to connect."
            case .credentialsRejected:
                return "ESPN rejected those cookies. They may have expired — sign in to ESPN again and re-copy them."
            case .leagueNotFound:
                return "No league with that ID for this season. Check the league ID from your ESPN league URL."
            case .noTeamForSWID:
                return "Connected to the league, but no team in it belongs to that SWID. Check you copied the SWID from the right ESPN account."
            case .status(let code):
                return "ESPN returned \(code)."
            case .transport(let detail):
                return detail
            }
        }
    }

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Cookies are supplied per request; never let the session persist ESPN's own.
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        self.session = URLSession(configuration: config)
    }

    // MARK: - Requests

    func matchup(credentials: Credentials, season: Int? = nil) async throws -> FantasyMatchup {
        let league = try await league(credentials: credentials, season: season)
        guard let swid = credentials.swid, !swid.isEmpty else {
            throw FantasyError.privateLeague
        }
        guard let matchup = FantasyMapper.matchup(from: league, swid: swid) else {
            throw FantasyError.noTeamForSWID
        }
        return matchup
    }

    /// The raw payload, for `--dump-fantasy` to record as a test fixture.
    func rawLeagueJSON(credentials: Credentials, season: Int? = nil) async throws -> Data {
        try await get(credentials: credentials, season: season).0
    }

    func league(credentials: Credentials, season: Int? = nil) async throws -> FantasyLeagueDTO {
        let (data, _) = try await get(credentials: credentials, season: season)
        do {
            return try JSONDecoder().decode(FantasyLeagueDTO.self, from: data)
        } catch {
            throw FantasyError.transport("Could not read ESPN's league response: \(error)")
        }
    }

    private func get(credentials: Credentials, season: Int?) async throws -> (Data, HTTPURLResponse) {
        let leagueID = credentials.leagueID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !leagueID.isEmpty else { throw FantasyError.noLeagueConfigured }

        let year = season ?? Self.currentSeason()
        var components = URLComponents(
            string: "https://lm-api-reads.fantasy.espn.com/apis/v3/games/ffl/seasons/\(year)/segments/0/leagues/\(leagueID)"
        )
        // Views are repeated keys, not a comma list. `scoringPeriodId` is deliberately
        // omitted so ESPN answers for the current week rather than one we guessed.
        components?.queryItems = ["mTeam", "mRoster", "mMatchupScore", "mSettings"]
            .map { URLQueryItem(name: "view", value: $0) }

        guard let url = components?.url else {
            throw FantasyError.transport("Could not build the league URL.")
        }

        var request = URLRequest(url: url)
        request.setValue("FootballWidget/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if credentials.hasCookies {
            let swid = Self.bracedSWID(credentials.swid ?? "")
            request.setValue("espn_s2=\(credentials.espnS2 ?? ""); SWID=\(swid)",
                             forHTTPHeaderField: "Cookie")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw FantasyError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw FantasyError.transport("Unexpected response from ESPN.")
        }

        switch http.statusCode {
        case 200..<300:
            return (data, http)
        case 401:
            // Distinguishing these is the whole point: without cookies it just means
            // the league is private, with them it means they are wrong or expired.
            throw credentials.hasCookies ? FantasyError.credentialsRejected : FantasyError.privateLeague
        case 404:
            throw FantasyError.leagueNotFound
        default:
            throw FantasyError.status(http.statusCode)
        }
    }

    // MARK: - Helpers

    /// ESPN wants the SWID wrapped in braces, but copies out of a browser sometimes
    /// include them and sometimes do not.
    static func bracedSWID(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if trimmed.hasPrefix("{") && trimmed.hasSuffix("}") { return trimmed }
        return "{\(trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "{}")))}"
    }

    /// The NFL season spans the new year, so January and February still belong to the
    /// previous season's league.
    static func currentSeason(now: Date = .now) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month], from: now)
        let year = parts.year ?? 2026
        return (parts.month ?? 9) < 3 ? year - 1 : year
    }

    /// Accepts a full ESPN URL or a bare id, since people paste both.
    static func parseLeagueID(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.allSatisfy(\.isNumber) { return trimmed }

        if let components = URLComponents(string: trimmed) {
            let names = ["leagueId", "leagueID", "leagueid"]
            for name in names {
                if let value = components.queryItems?.first(where: { $0.name == name })?.value,
                   !value.isEmpty {
                    return value
                }
            }
        }
        // Fall back to the longest digit run, which covers hand-typed fragments.
        let runs = trimmed.split { !$0.isNumber }.map(String.init)
        return runs.max { $0.count < $1.count }
    }
}
