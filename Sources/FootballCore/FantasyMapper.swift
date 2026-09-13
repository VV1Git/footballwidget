import Foundation

public enum FantasyMapper {

    /// Builds your matchup for the week from a league payload.
    ///
    /// Your own team is found via the SWID: it is the id of your entry in `members`,
    /// and the team whose `owners` contains it is yours. That means you never have to
    /// pick your team from a list, and it stays correct if the league is renamed.
    public static func matchup(
        from dto: FantasyLeagueDTO,
        swid: String,
        week: Int? = nil
    ) -> FantasyMatchup? {
        let teams = (dto.teams ?? []).compacted()
        guard !teams.isEmpty else { return nil }

        let scoringPeriod = week ?? dto.scoringPeriodId ?? dto.status?.latestScoringPeriod ?? 1
        let matchupPeriod = dto.status?.currentMatchupPeriod ?? scoringPeriod

        guard let myTeamID = myTeamID(in: dto, swid: swid) else { return nil }

        let schedule = (dto.schedule ?? []).compacted()
        let matchup = schedule.first { entry in
            (entry.matchupPeriodId ?? matchupPeriod) == matchupPeriod
                && (entry.home?.teamId == myTeamID || entry.away?.teamId == myTeamID)
        }

        var mineSide: FantasyMatchupSideDTO?
        var theirSide: FantasyMatchupSideDTO?
        if let matchup {
            mineSide = side(in: matchup, teamID: myTeamID)
            theirSide = opponentSide(in: matchup, myTeamID: myTeamID)
        }

        guard let mine = team(id: myTeamID, teams: teams, side: mineSide,
                              scoringPeriod: scoringPeriod) else { return nil }

        var opponent: FantasyTeam?
        if let opponentTeamID = theirSide?.teamId {
            opponent = team(id: opponentTeamID, teams: teams, side: theirSide,
                            scoringPeriod: scoringPeriod)
        }

        return FantasyMatchup(
            leagueName: dto.settings?.name ?? "Fantasy",
            week: matchupPeriod,
            mine: mine,
            opponent: opponent
        )
    }

    /// Your SWID identifies you in `members`; the team that lists you as an owner is
    /// yours. ESPN is inconsistent about the surrounding braces and letter case, so
    /// compare loosely.
    static func myTeamID(in dto: FantasyLeagueDTO, swid: String) -> Int? {
        let normalized = normalizeSWID(swid)
        guard !normalized.isEmpty else { return nil }

        let members = (dto.members ?? []).compacted()
        let me = members.first { normalizeSWID($0.id ?? "") == normalized }
        let myMemberID = me?.id ?? swid

        let teams = (dto.teams ?? []).compacted()
        let owned = teams.first { team in
            (team.owners ?? []).contains { normalizeSWID($0) == normalizeSWID(myMemberID) }
        }
        return owned?.id
    }

    static func normalizeSWID(_ raw: String) -> String {
        raw.trimmingCharacters(in: CharacterSet(charactersIn: "{} \n\t")).uppercased()
    }

    // MARK: - Pieces

    static func side(in matchup: FantasyMatchupDTO, teamID: Int) -> FantasyMatchupSideDTO? {
        if matchup.home?.teamId == teamID { return matchup.home }
        if matchup.away?.teamId == teamID { return matchup.away }
        return nil
    }

    static func opponentSide(in matchup: FantasyMatchupDTO, myTeamID: Int) -> FantasyMatchupSideDTO? {
        if matchup.home?.teamId == myTeamID { return matchup.away }
        if matchup.away?.teamId == myTeamID { return matchup.home }
        return nil
    }

    static func team(
        id: Int,
        teams: [FantasyTeamDTO],
        side: FantasyMatchupSideDTO?,
        scoringPeriod: Int?
    ) -> FantasyTeam? {
        let dto = teams.first { $0.id == id }

        // Two rosters come back and they are not equivalent. The one hanging off the
        // matchup carries stub entries — no player id, no applied total, just a lineup
        // slot — while `teams[].roster` has the whole thing. Build from each and keep
        // whichever actually yielded players, rather than trusting a fixed order.
        let rosterCandidates = [
            dto?.roster,
            side?.rosterForCurrentScoringPeriod,
            side?.rosterForMatchupPeriod,
        ].compactMap { $0 }

        var roster: [RosterPlayer] = []
        var rosterApplied: Double = 0
        for candidate in rosterCandidates {
            let players = (candidate.entries ?? []).compacted()
                .compactMap { player(from: $0, scoringPeriod: scoringPeriod) }
            if players.count > roster.count {
                roster = players
                rosterApplied = candidate.appliedStatTotal ?? 0
            }
        }

        // Four ways of saying the same thing, any of which can be zero depending on
        // whether the week is in progress or settled. Taking the largest picks the
        // live score during the games and the final score afterwards, without having
        // to guess which phase we are in.
        let summed = roster.filter(\.isStarter).reduce(0) { $0 + $1.points }
        let liveSum = (summed * 100).rounded() / 100
        let total = max(
            max(side?.totalPointsLive ?? 0, side?.totalPoints ?? 0),
            max(rosterApplied, liveSum)
        )

        return FantasyTeam(
            id: id,
            name: displayName(of: dto) ?? "Team \(id)",
            abbreviation: dto?.abbrev ?? "T\(id)",
            points: total,
            roster: roster
        )
    }

    static func displayName(of dto: FantasyTeamDTO?) -> String? {
        guard let dto else { return nil }
        if let name = dto.name, !name.isEmpty { return name }
        // Older leagues split the name in two.
        let joined = [dto.location, dto.nickname]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }

    static func player(from entry: FantasyRosterEntryDTO, scoringPeriod: Int?) -> RosterPlayer? {
        let pool = entry.playerPoolEntry
        let dto = pool?.player
        guard let id = dto?.id ?? entry.playerId ?? pool?.id else { return nil }

        let full = dto?.fullName ?? "Player \(id)"
        let first = dto?.firstName ?? full.components(separatedBy: " ").first ?? ""
        let last = dto?.lastName
            ?? full.components(separatedBy: " ").dropFirst().joined(separator: " ")

        return RosterPlayer(
            id: id,
            fullName: full,
            firstName: first,
            lastName: last.isEmpty ? full : last,
            position: FantasyPosition.from(id: dto?.defaultPositionId),
            slot: LineupSlot.from(id: entry.lineupSlotId),
            proTeamID: dto?.proTeamId,
            points: pool?.appliedStatTotal ?? actualPoints(from: dto?.stats, scoringPeriod: scoringPeriod),
            injuryStatus: dto?.injuryStatus
        )
    }

    /// `appliedStatTotal` is the live number, but some views only carry the stat array.
    /// `statSourceId == 0` is actual production; 1 is a projection and must not be
    /// mistaken for points already scored. The array also holds other weeks, so the
    /// current scoring period wins when we know which one that is.
    static func actualPoints(
        from stats: [Failable<FantasyPlayerStatDTO>]?,
        scoringPeriod: Int? = nil
    ) -> Double {
        let entries = (stats ?? []).compacted().filter { $0.statSourceId == 0 }
        if let scoringPeriod,
           let match = entries.first(where: { $0.scoringPeriodId == scoringPeriod }) {
            return match.appliedTotal ?? 0
        }
        return entries.first?.appliedTotal ?? 0
    }
}
