import Foundation
import FootballCore

/// Reads ESPN's public NFL endpoints.
///
/// These are undocumented, so every request is conditional (ETag) to stay light, and
/// a 304 is reported as "unchanged" rather than as an error.
actor ESPNClient {
    struct Team: Identifiable, Hashable, Sendable {
        let id: String
        let abbreviation: String
        let displayName: String
        let colorHex: String?
    }

    enum Fetch<T: Sendable>: Sendable {
        case updated(T)
        case unchanged
    }

    private let session: URLSession
    private var etags: [String: String] = [:]

    private static let base = "https://site.api.espn.com/apis/site/v2/sports/football/nfl"

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = false
        // We do our own conditional requests; the URL cache would only duplicate them.
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
    }

    // MARK: - Requests

    func scoreboard() async throws -> Fetch<[Game]> {
        let result: Fetch<ESPNScoreboardDTO> = try await get("\(Self.base)/scoreboard")
        switch result {
        case .unchanged: return .unchanged
        case .updated(let dto): return .updated(ESPNMapper.games(from: dto))
        }
    }

    func summary(gameID: String) async throws -> Fetch<GameDetail> {
        let result: Fetch<ESPNSummaryDTO> = try await get("\(Self.base)/summary?event=\(gameID)")
        switch result {
        case .unchanged: return .unchanged
        case .updated(let dto): return .updated(ESPNMapper.detail(from: dto, gameID: gameID))
        }
    }

    /// The 32 teams, for the favorites picker.
    func allTeams() async throws -> [Team] {
        struct Response: Decodable {
            struct Sport: Decodable { let leagues: [League]? }
            struct League: Decodable { let teams: [Entry]? }
            struct Entry: Decodable { let team: ESPNTeamDTO? }
            let sports: [Sport]?
        }
        let result: Fetch<Response> = try await get("\(Self.base)/teams", useETag: false)
        guard case .updated(let dto) = result else { return [] }
        let entries = dto.sports?.first?.leagues?.first?.teams ?? []
        return entries.compactMap { entry in
            guard let t = entry.team, let id = t.id, let abbr = t.abbreviation else { return nil }
            return Team(id: id, abbreviation: abbr,
                        displayName: t.displayName ?? abbr, colorHex: t.color)
        }
        .sorted { $0.displayName < $1.displayName }
    }

    // MARK: - Transport

    private func get<T: Decodable & Sendable>(
        _ urlString: String,
        useETag: Bool = true
    ) async throws -> Fetch<T> {
        guard let url = URL(string: urlString) else { throw ClientError.badURL(urlString) }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // ESPN serves a stale/limited body to clients with no UA.
        request.setValue("FootballWidget/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if useETag, let tag = etags[urlString] {
            request.setValue(tag, forHTTPHeaderField: "If-None-Match")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.notHTTP }

        if http.statusCode == 304 { return .unchanged }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.status(http.statusCode)
        }
        if useETag, let tag = http.value(forHTTPHeaderField: "ETag") {
            etags[urlString] = tag
        }

        do {
            return .updated(try JSONDecoder().decode(T.self, from: data))
        } catch {
            throw ClientError.decoding(String(describing: error))
        }
    }

    enum ClientError: LocalizedError {
        case badURL(String)
        case notHTTP
        case status(Int)
        case decoding(String)

        var errorDescription: String? {
            switch self {
            case .badURL(let s): return "Bad URL: \(s)"
            case .notHTTP: return "Unexpected response"
            case .status(let code): return "ESPN returned \(code)"
            case .decoding(let detail): return "Could not read ESPN's response: \(detail)"
            }
        }
    }
}
