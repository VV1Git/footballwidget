import Foundation

/// Turns ESPN's wire payloads into the domain model, tolerating anything missing.
public enum ESPNMapper {

    // MARK: - Dates

    /// ESPN sends `2026-09-10T00:20Z` — no seconds — which `ISO8601DateFormatter`
    /// rejects under `.withInternetDateTime`. Try the shapes it actually uses.
    private static let dateFormatters: [DateFormatter] = {
        ["yyyy-MM-dd'T'HH:mmXXXXX", "yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"]
            .map { format in
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.timeZone = TimeZone(secondsFromGMT: 0)
                f.dateFormat = format
                return f
            }
    }()

    public static func parseDate(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        for f in dateFormatters {
            if let d = f.date(from: string) { return d }
        }
        return nil
    }

    // MARK: - Scoreboard

    public static func games(from dto: ESPNScoreboardDTO) -> [Game] {
        (dto.events ?? []).compacted().compactMap(game(from:))
    }

    public static func game(from event: ESPNEventDTO) -> Game? {
        guard let id = event.id else { return nil }
        let comp = event.competitions?.compacted().first
        let status = comp?.status ?? event.status
        let competitors = comp?.competitors?.compacted() ?? []

        guard
            let homeDTO = competitors.first(where: { $0.homeAway == "home" }),
            let awayDTO = competitors.first(where: { $0.homeAway == "away" })
        else { return nil }

        let situation = situation(from: comp?.situation)
        var home = teamSide(from: homeDTO)
        var away = teamSide(from: awayDTO)
        home.timeoutsLeft = situation?.homeTimeouts
        away.timeoutsLeft = situation?.awayTimeouts

        return Game(
            id: id,
            shortName: event.shortName ?? "\(away.abbreviation) @ \(home.abbreviation)",
            kickoff: parseDate(event.date ?? comp?.date),
            phase: phase(from: status),
            statusDetail: status?.type?.shortDetail ?? status?.type?.description ?? "",
            period: status?.period ?? 0,
            displayClock: status?.displayClock ?? "",
            home: home,
            away: away,
            situation: situation,
            broadcast: comp?.broadcasts?.first?.names?.first,
            venue: comp?.venue?.fullName
        )
    }

    static func phase(from status: ESPNStatusDTO?) -> GamePhase {
        let name = status?.type?.name ?? ""
        if name == "STATUS_HALFTIME" { return .halftime }
        switch status?.type?.state {
        case "pre": return .pre
        case "in": return .live
        case "post": return .final
        default: return .unknown
        }
    }

    static func teamSide(from dto: ESPNCompetitorDTO) -> TeamSide {
        let team = dto.team
        let overall = dto.records?.first(where: { $0.type == "total" }) ?? dto.records?.first
        return TeamSide(
            // The NFL team id, not the competitor id. They are equal in every payload
            // seen so far, but this is the id the fantasy roster joins against via
            // `proTeamId`, so take it from the team rather than rely on that holding.
            id: team?.id ?? dto.id ?? UUID().uuidString,
            abbreviation: team?.abbreviation ?? "—",
            displayName: team?.displayName ?? team?.name ?? "—",
            shortName: team?.shortDisplayName ?? team?.name ?? team?.abbreviation ?? "—",
            score: Int(dto.score ?? "0") ?? 0,
            record: overall?.summary,
            primaryHex: team?.color,
            secondaryHex: team?.alternateColor,
            logoURL: team?.logo.flatMap(URL.init(string:)),
            isWinner: dto.winner ?? false
        )
    }

    static func situation(from dto: ESPNSituationDTO?) -> Situation? {
        guard let dto else { return nil }
        return Situation(
            possessionTeamID: dto.possession,
            shortDownDistance: dto.shortDownDistanceText,
            downDistanceText: dto.downDistanceText,
            possessionText: dto.possessionText,
            yardLine: dto.yardLine,
            down: dto.down,
            distance: dto.distance,
            isRedZone: dto.isRedZone ?? false,
            homeTimeouts: dto.homeTimeouts,
            awayTimeouts: dto.awayTimeouts,
            lastPlayText: dto.lastPlay?.text,
            lastPlayID: dto.lastPlay?.id,
            lastPlayTypeID: dto.lastPlay?.type?.id,
            lastPlayWasScoring: dto.lastPlay?.scoringPlay ?? false,
            // The scoreboard's `lastPlay` is a trimmed play object that does not always
            // carry `isTurnover`, so fall back to the play type.
            lastPlayWasTurnover: dto.lastPlay?.isTurnover
                ?? dto.lastPlay?.type?.id.map(FieldGeometry.turnoverTypeIDs.contains)
                ?? false
        )
    }

    // MARK: - Summary

    public static func detail(from dto: ESPNSummaryDTO, gameID: String) -> GameDetail {
        var drives: [Drive] = []
        // Newest first: the in-progress drive, then completed drives in reverse.
        if let current = dto.drives?.current {
            drives.append(drive(from: current, isCurrent: true))
        }
        for d in (dto.drives?.previous ?? []).compacted().reversed() {
            drives.append(drive(from: d, isCurrent: false))
        }
        // A live drive sometimes appears in both `current` and the tail of `previous`.
        var seen = Set<String>()
        drives = drives.filter { seen.insert($0.id).inserted }

        return GameDetail(
            gameID: gameID,
            drives: drives,
            scoringPlayIDs: (dto.scoringPlays ?? []).compacted().compactMap(\.id)
        )
    }

    static func drive(from dto: ESPNDriveDTO, isCurrent: Bool) -> Drive {
        let plays = (dto.plays ?? []).compacted().enumerated().map { play(from: $1, sequence: $0) }
        let scrimmagePlays = plays.filter { $0.kind != .administrative }
        let yards = dto.yards ?? 0
        let elapsed = dto.timeElapsed?.displayValue ?? ""

        var bits: [String] = []
        let count = dto.offensivePlays ?? scrimmagePlays.count
        bits.append("\(count) play\(count == 1 ? "" : "s")")
        bits.append("\(yards) yd\(abs(yards) == 1 ? "" : "s")")
        if !elapsed.isEmpty { bits.append(elapsed) }

        return Drive(
            id: dto.id ?? UUID().uuidString,
            teamID: dto.team?.id,
            teamAbbreviation: dto.team?.abbreviation ?? "—",
            result: dto.displayResult ?? dto.result ?? (isCurrent ? "In progress" : "—"),
            isScore: dto.isScore ?? false,
            yards: yards,
            playCount: count,
            timeElapsed: elapsed,
            summary: bits.joined(separator: ", "),
            startText: dto.start?.text,
            endText: dto.end?.text,
            plays: plays,
            isCurrent: isCurrent
        )
    }

    static func play(from dto: ESPNPlayDTO, sequence: Int) -> Play {
        let start = node(from: dto.start)
        let end = node(from: dto.end)
        let isTurnover = dto.isTurnover ?? false
        return Play(
            id: dto.id ?? "\(sequence)-\(dto.sequenceNumber ?? UUID().uuidString)",
            sequence: Int(dto.sequenceNumber ?? "") ?? sequence,
            typeID: dto.type?.id,
            typeText: dto.type?.text ?? "Play",
            text: dto.text ?? dto.shortText ?? "",
            downDistanceText: dto.start?.downDistanceText,
            yards: dto.statYardage ?? 0,
            period: dto.period?.number ?? 0,
            clock: dto.clock?.displayValue ?? "",
            isScoring: dto.scoringPlay ?? false,
            isTurnover: isTurnover,
            isPenalty: dto.isPenalty ?? false,
            homeScore: dto.homeScore,
            awayScore: dto.awayScore,
            start: start,
            end: end,
            kind: FieldGeometry.classify(
                typeID: dto.type?.id, isTurnover: isTurnover, start: start, end: end
            )
        )
    }

    static func node(from dto: ESPNPlayNodeDTO?) -> PlayNode {
        PlayNode(
            teamID: dto?.team?.id,
            yardsToEndzone: dto?.yardsToEndzone,
            yardLine: dto?.yardLine,
            down: dto?.down,
            distance: dto?.distance
        )
    }
}
