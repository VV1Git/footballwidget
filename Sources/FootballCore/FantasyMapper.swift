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
            opponent: opponent,
            espnWinProbability: mineSide?.winProbability,
            outcome: matchup.flatMap { outcome(of: $0, myTeamID: myTeamID) },
            scoringPeriod: scoringPeriod,
            scoringRules: scoringRules(from: dto.settings?.scoringSettings?.value)
        )
    }

    /// The league's scoring table as stat id → points. An item without a stat id or a
    /// value is dropped; a stat listed twice keeps its last line, as ESPN's own screens
    /// show only one.
    static func scoringRules(from dto: FantasyScoringSettingsDTO?) -> FantasyScoringRules {
        var points: [Int: Double] = [:]
        var overrides: [Int: [Int: Double]] = [:]
        for item in (dto?.scoringItems ?? []).compacted() {
            guard let stat = item.statId, let value = item.points else { continue }
            points[stat] = value
            let bySlot = (item.pointsOverrides ?? [:]).reduce(into: [Int: Double]()) { result, entry in
                if let slot = Int(entry.key) { result[slot] = entry.value }
            }
            overrides[stat] = bySlot.isEmpty ? nil : bySlot
        }
        return FantasyScoringRules(points: points, overrides: overrides)
    }

    /// ESPN names the winning side as home or away, so it has to be turned round to
    /// read from yours. Anything other than a settled result — "UNDECIDED", a missing
    /// field, a spelling ESPN has not used yet — is left undecided rather than guessed.
    static func outcome(of matchup: FantasyMatchupDTO, myTeamID: Int) -> MatchupOutcome? {
        guard let winner = matchup.winner?.uppercased() else { return nil }
        let iAmHome = matchup.home?.teamId == myTeamID
        switch winner {
        case "TIE": return .tied
        case "HOME": return iAmHome ? .won : .lost
        case "AWAY": return iAmHome ? .lost : .won
        default: return nil
        }
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
        for candidate in rosterCandidates {
            let players = (candidate.entries ?? []).compacted()
                .compactMap { player(from: $0, scoringPeriod: scoringPeriod) }
            if players.count > roster.count { roster = players }
        }

        // Three ways of saying the same thing, any of which can be zero depending on
        // whether the week is in progress or settled: `totalPointsLive` moves during
        // the games, `totalPoints` is filled in once the week settles, and the starters
        // add up to the same figure in both phases. Taking the largest picks whichever
        // of them is populated without having to guess which phase we are in.
        //
        // The roster's own `appliedStatTotal` used to take part here and must not.
        // It is not scoped to a week: ESPN leaves the previous week's total in it
        // until the new week's first game kicks off, so from the end of Monday night
        // football until Thursday it holds a finished week's points — larger than the
        // real zero, so it won the `max` and the matchup view showed last week's score
        // against this week's opponent.
        let summed = roster.filter(\.isStarter).reduce(0) { $0 + $1.points }
        let liveSum = (summed * 100).rounded() / 100
        let largest = max(
            max(side?.totalPointsLive ?? 0, side?.totalPoints ?? 0),
            liveSum
        )
        // Rounded again because ESPN's own totals can arrive drifted
        // (59.300000000000004), and being a hair larger they win the `max`.
        let total = (largest * 100).rounded() / 100

        return FantasyTeam(
            id: id,
            name: displayName(of: dto) ?? "Team \(id)",
            abbreviation: dto?.abbrev ?? "T\(id)",
            points: total,
            roster: roster,
            projectedPoints: side?.totalProjectedPointsLive
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
            points: points(pool: pool, stats: dto?.stats, scoringPeriod: scoringPeriod),
            injuryStatus: dto?.injuryStatus,
            projectedPoints: projectedPoints(from: dto?.stats, scoringPeriod: scoringPeriod)
        )
    }

    /// What this player has actually scored in `scoringPeriod`.
    ///
    /// `appliedStatTotal` is the number that moves during a game, but it is not scoped
    /// to a week: until the new week's first game kicks off ESPN still has the previous
    /// week's total sitting in it. The per-period stat line is the one that resets, so
    /// when the period is known and the player carries stats, that line decides — and
    /// no line for the period means nothing scored yet, which is exactly what should
    /// be shown on a Tuesday. Checked against a payload recorded mid-Sunday: every one
    /// of its players' period lines matched `appliedStatTotal` to the cent, so nothing
    /// is given up on liveness by preferring it.
    ///
    /// `appliedStatTotal` stays as the fallback for the views that send no stats at all.
    static func points(
        pool: FantasyPlayerPoolEntryDTO?,
        stats: [Failable<FantasyPlayerStatDTO>]?,
        scoringPeriod: Int?
    ) -> Double {
        guard scoringPeriod != nil, !(stats ?? []).compacted().isEmpty else {
            return pool?.appliedStatTotal ?? 0
        }
        return actualPoints(from: stats, scoringPeriod: scoringPeriod)
    }

    /// `appliedStatTotal` is the live number, but some views only carry the stat array.
    /// `statSourceId == 0` is actual production; 1 is a projection and must not be
    /// mistaken for points already scored. The array also holds other weeks, so the
    /// current scoring period wins when we know which one that is.
    ///
    /// When the week is known but has no line, the answer is zero. Falling back to the
    /// first actual would pick up whatever else is in the array, and in a real payload
    /// a player who has not played yet carries last season's total there.
    static func actualPoints(
        from stats: [Failable<FantasyPlayerStatDTO>]?,
        scoringPeriod: Int? = nil
    ) -> Double {
        let entries = (stats ?? []).compacted().filter { $0.statSourceId == 0 }
        if let scoringPeriod {
            return entries.first(where: { $0.scoringPeriodId == scoringPeriod })?.appliedTotal ?? 0
        }
        return entries.first?.appliedTotal ?? 0
    }

    /// This week's projection: `statSourceId == 1` for exactly this scoring period.
    ///
    /// The period match is what matters. Beside the weekly line, a roster carries a
    /// whole-season projection (period 0) that is twenty times bigger, and a win
    /// probability built on that would be nonsense. With no known period nothing is
    /// returned, so a missing projection stays missing instead of becoming a guess.
    static func projectedPoints(
        from stats: [Failable<FantasyPlayerStatDTO>]?,
        scoringPeriod: Int?
    ) -> Double? {
        guard let scoringPeriod else { return nil }
        return (stats ?? []).compacted()
            .first { $0.statSourceId == 1 && $0.scoringPeriodId == scoringPeriod }?
            .appliedTotal
    }
}
