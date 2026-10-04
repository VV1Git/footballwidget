import Foundation
import FootballCore

/// Reads ESPN's public NFL endpoints.
///
/// These are undocumented, so every request is conditional (ETag) to stay light, and
/// a 304 is reported as "unchanged" rather than as an error.
///
/// In practice ESPN sends neither `ETag` nor `Last-Modified` on the scoreboard or the
/// play feed, so the 304 never comes: a live Sunday logged every one of several hundred
/// requests as a full 200. What does happen is that a body is often byte-for-byte the
/// previous one — 7 of 17 scoreboard polls and 11 of 17 play-feed polls in a recording
/// at five-second spacing — so a body whose fingerprint matches the last one for that
/// URL is reported as "unchanged" too, before any decoding.
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
    private var fingerprints = BodyFingerprints()
    /// Off for a client whose caller needs every answer as a value — `ReplaySource`
    /// loads its game once and would be left with nothing if a retry said "unchanged".
    private let reportsRepeatedBodies: Bool

    private static let base = "https://site.api.espn.com/apis/site/v2/sports/football/nfl"

    /// `reportsRepeatedBodies`: report a body identical to the last one for the same URL
    /// as `.unchanged`. The caller must then keep what it already has, as for a 304.
    init(reportsRepeatedBodies: Bool = true) {
        self.reportsRepeatedBodies = reportsRepeatedBodies
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = false
        // We do our own conditional requests; the URL cache would only duplicate them.
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
    }

    // MARK: - Requests

    func scoreboard() async throws -> Fetch<[Game]> {
        let thisWeek = "\(Self.base)/scoreboard"
        let result: Fetch<ESPNScoreboardDTO> = try await get(thisWeek)
        guard case .updated(let dto) = result else { return .unchanged }

        let games = ESPNMapper.games(from: dto)
        // ESPN's week ends on Wednesday morning UTC, not when the football does, so
        // from the end of Monday night until then the default scoreboard is a full set
        // of finals and the coming week is nowhere in it. Once there is nothing left to
        // play in the week we were handed, ask for the next one by name.
        guard !games.isEmpty, games.allSatisfy({ $0.phase == .final }),
              let next = ScoreboardCalendar.nextWeek(after: .now, in: dto)
        else { return .updated(games) }

        let url = "\(Self.base)/scoreboard?week=\(next.number)&seasontype=\(next.seasonType)"
        do {
            // "Unchanged" has to be passed on rather than treated as "nothing there".
            // The next week's slate sits still for days, so its body repeats on every
            // poll — answering with `games` instead would flip the panel back to the
            // finals this whole detour exists to get past.
            switch try await get(url) as Fetch<ESPNScoreboardDTO> {
            case .unchanged:
                return .unchanged
            case .updated(let nextDTO):
                let nextGames = ESPNMapper.games(from: nextDTO)
                return .updated(nextGames.isEmpty ? games : nextGames)
            }
        } catch {
            // A failed substitution costs the upcoming slate, never the one in hand. Both
            // bodies are forgotten so the next poll tries again: remembered, the default
            // one came back "unchanged" on every poll after and the detour never re-ran,
            // leaving last week's finals up until ESPN rolled the week on Wednesday.
            fingerprints.forget(thisWeek)
            fingerprints.forget(url)
            return .updated(games)
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

        let checksBody = useETag && reportsRepeatedBodies
        let fingerprint = checksBody ? BodyFingerprints.fingerprint(data) : 0
        if checksBody, fingerprints.matches(fingerprint, for: urlString) { return .unchanged }

        do {
            let decoded = try JSONDecoder().decode(T.self, from: data)
            if checksBody { fingerprints.remember(fingerprint, for: urlString) }
            return .updated(decoded)
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
