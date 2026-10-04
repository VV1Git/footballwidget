import Foundation

/// ESPN's fantasy stat ids: the keys of a league's scoring table and of a player's stat
/// line.
///
/// Read off recorded league data rather than taken on trust. A live Sunday was polled
/// every fifteen seconds, and each change in a player's stat line was lined up with the
/// play that caused it and with ESPN's applied points for each id — which is how, say,
/// 3 is known to be passing yards worth 0.04 a yard and 53 to be the catch that pays a
/// point in PPR. Whole-game totals from the recorded NE @ SEA feed then pinned passing
/// touchdowns (4) and interceptions (20), which never moved during the recording.
/// Ids marked "not yet seen" follow the layout of the ones that were — made, attempted
/// and missed in threes, distance bonuses beside the stat they belong to — but nothing
/// recorded has exercised them yet.
public enum FantasyStat {
    // Passing
    public static let passAttempts = 0
    public static let passCompletions = 1
    /// Attempts minus completions, so an interception counts as one too: a recorded
    /// line read 51 attempts, 32 completions and 19 incompletions, picks on it.
    public static let passIncompletions = 2
    public static let passingYards = 3
    public static let passingTouchdowns = 4
    public static let passingTouchdown40Plus = 15        // not yet seen
    public static let passingTouchdown50Plus = 16        // not yet seen
    public static let passingTwoPointConversions = 19    // not yet seen
    public static let interceptionsThrown = 20
    public static let timesSacked = 64

    // Rushing
    public static let rushAttempts = 23
    public static let rushingYards = 24
    public static let rushingTouchdowns = 25
    public static let rushingTwoPointConversions = 26    // not yet seen
    public static let rushingTouchdown40Plus = 35        // not yet seen
    public static let rushingTouchdown50Plus = 36        // not yet seen

    // Receiving
    /// Moves in step with 53. Leagues score 53, so both are carried and the table picks.
    public static let receptionsCounted = 41
    public static let receivingYards = 42
    public static let receivingTouchdowns = 43
    public static let receivingTwoPointConversions = 44
    public static let receivingTouchdown40Plus = 45      // not yet seen
    public static let receivingTouchdown50Plus = 46      // not yet seen
    public static let receptions = 53
    public static let targets = 58

    // Ball security
    public static let fumbles = 68
    public static let fumblesLost = 72                   // not yet seen
    /// An offensive player falling on a loose ball in the end zone. Not yet seen.
    public static let fumbleRecoveredForTouchdown = 63

    // Kicking. Made, attempted, missed for each distance; 80 (under 40), 85 (missed)
    // and 198 (50–59) have been seen paying points, the rest follow their pattern.
    public static let fieldGoalsMade50Plus = 74
    public static let fieldGoalsAttempted50Plus = 75
    public static let fieldGoalsMissed50Plus = 76
    public static let fieldGoalsMade40To49 = 77
    public static let fieldGoalsAttempted40To49 = 78
    public static let fieldGoalsMissed40To49 = 79
    public static let fieldGoalsMadeUnder40 = 80
    public static let fieldGoalsAttemptedUnder40 = 81
    public static let fieldGoalsMissedUnder40 = 82
    public static let fieldGoalsMade = 83
    public static let fieldGoalsAttempted = 84
    public static let fieldGoalsMissed = 85
    public static let extraPointsMade = 86
    public static let extraPointsAttempted = 87
    public static let extraPointsMissed = 88             // not yet seen
    public static let fieldGoalsMade50To59 = 198
    public static let fieldGoalsAttempted50To59 = 199
    public static let fieldGoalsMissed50To59 = 200
    public static let fieldGoalsMade60Plus = 201
    public static let fieldGoalsAttempted60Plus = 202
    public static let fieldGoalsMissed60Plus = 203

    // Team defense and special teams. 99 has been seen paying a point a sack, and 95
    // carrying points on a defense's line beside it; the rest are not yet seen.
    public static let blockedKickReturnTouchdowns = 93
    public static let defensiveInterceptions = 95
    public static let defensiveFumbleRecoveries = 96
    public static let defensiveBlockedKicks = 97
    public static let defensiveSafeties = 98
    public static let defensiveSacks = 99
    /// Shared by a returner and his team's defense, as both are credited.
    public static let kickoffReturnTouchdowns = 101
    public static let puntReturnTouchdowns = 102
    public static let interceptionReturnTouchdowns = 103
    public static let fumbleReturnTouchdowns = 104

    /// Stats worth one unit per `per` yards of the game total: every 5, 10, 20, 25, 50
    /// and 100 passing, rushing and receiving yards. All but the 100s were seen stepping
    /// at exactly those totals, and a back at -4 rushing yards had none.
    static let yardageChunks: [(total: Int, stat: Int, per: Int)] = [
        (passingYards, 5, 5), (passingYards, 6, 10), (passingYards, 7, 20),
        (passingYards, 8, 25), (passingYards, 9, 50), (passingYards, 10, 100),
        (rushingYards, 27, 5), (rushingYards, 28, 10), (rushingYards, 29, 20),
        (rushingYards, 30, 25), (rushingYards, 31, 50), (rushingYards, 32, 100),
        (receivingYards, 47, 5), (receivingYards, 48, 10), (receivingYards, 49, 20),
        (receivingYards, 50, 25), (receivingYards, 51, 50), (receivingYards, 52, 100),
    ]

    /// Game milestones: 1 while the game total is in the range, 0 otherwise — a
    /// 300–399 passing game, 400+, a 100–199 rushing or receiving game, 200+. Not yet
    /// seen.
    static let milestones: [(total: Int, stat: Int, range: Range<Int>)] = [
        (passingYards, 17, 300..<400), (passingYards, 18, 400..<Int.max),
        (rushingYards, 37, 100..<200), (rushingYards, 38, 200..<Int.max),
        (receivingYards, 56, 100..<200), (receivingYards, 57, 200..<Int.max),
    ]

    static let touchdowns: Set<Int> = [
        passingTouchdowns, rushingTouchdowns, receivingTouchdowns, fumbleRecoveredForTouchdown,
        blockedKickReturnTouchdowns, kickoffReturnTouchdowns, puntReturnTouchdowns,
        interceptionReturnTouchdowns, fumbleReturnTouchdowns,
    ]
}

/// What one player did on one play, as ESPN stat id → amount.
public struct FantasyStatLine: Sendable, Hashable {
    public private(set) var values: [Int: Double]

    public init(_ values: [Int: Double] = [:]) {
        self.values = values.filter { $0.value != 0 }
    }

    public subscript(stat: Int) -> Double { values[stat] ?? 0 }

    public mutating func add(_ stat: Int, _ amount: Double = 1) {
        let total = (values[stat] ?? 0) + amount
        values[stat] = total == 0 ? nil : total
    }

    public var isEmpty: Bool { values.isEmpty }

    /// He scored or threw a touchdown, or his defense did.
    public var isTouchdown: Bool {
        values.contains { FantasyStat.touchdowns.contains($0.key) && $0.value > 0 }
    }
}

/// A league's scoring table: what one unit of each ESPN stat is worth.
public struct FantasyScoringRules: Sendable, Hashable {
    public var points: [Int: Double]
    /// Stat id → lineup slot id → points, for a stat the league scores differently by
    /// position. The slot is the one the position plays in, not where he is lined up
    /// this week: ESPN scores a tight end in the flex as a tight end.
    public var overrides: [Int: [Int: Double]]

    public init(points: [Int: Double] = [:], overrides: [Int: [Int: Double]] = [:]) {
        self.points = points
        self.overrides = overrides
    }

    public var isEmpty: Bool { points.isEmpty }

    public func value(of stat: Int, for position: FantasyPosition) -> Double {
        if let slot = position.lineupSlotID, let override = overrides[stat]?[slot] {
            return override
        }
        return points[stat] ?? 0
    }

    /// Rounded to the cent, as ESPN's own figures are; summing doubles is not.
    public func points(for line: FantasyStatLine, position: FantasyPosition) -> Double {
        let total = line.values.reduce(0.0) { $0 + $1.value * value(of: $1.key, for: position) }
        return (total * 100).rounded() / 100
    }
}

extension FantasyPosition {
    /// The lineup slot this position plays in, which is what ESPN keys a per-position
    /// scoring override by.
    var lineupSlotID: Int? {
        switch self {
        case .quarterback: return 0
        case .runningBack: return 2
        case .wideReceiver: return 4
        case .tightEnd: return 6
        case .defense: return 16
        case .kicker: return 17
        case .other: return nil
        }
    }
}

/// One play of a game from one player's side.
public struct FantasyPlayLine: Sendable, Hashable {
    public var play: Play
    public var stats: FantasyStatLine
    /// ESPN's placeholder while a replay is looked at. It scores nothing until the
    /// ruling replaces it.
    public var isUnderReview: Bool

    public init(play: Play, stats: FantasyStatLine, isUnderReview: Bool = false) {
        self.play = play
        self.stats = stats
        self.isUnderReview = isUnderReview
    }
}

/// Works out each rostered player's stat line, play by play, from a game's play feed —
/// so a play's fantasy points are known the moment it appears, rather than whenever
/// ESPN's running totals catch up with it.
///
/// Stats come out of `PlaySummary`, by role: the passer and the catcher of a completion,
/// the runner, the kicker. Being named is not enough, so a tackler or a player flagged
/// for a penalty is never credited. A play wiped out by a flag, a placeholder awaiting
/// a replay ruling and anything with a lateral in it score nothing: the parser cannot
/// say how the yards split, and a wrong number is worse than none. Yardage chunks and
/// milestones (a point every 10 rushing yards, a 100-yard game) are game totals, so
/// they are counted on the play that crossed the line.
///
/// A team defense's points-allowed and yards-allowed tiers belong to the game rather
/// than to any play and are left out; so is a missed field goal returned for a score,
/// which has no id seen yet.
public struct FantasyGameScorer: Sendable {

    private struct Snap: Sendable {
        var play: Play
        var summary: PlaySummary
        /// A try posted on its own after a touchdown whose text already carries it.
        var isRepeatedTry: Bool
        // Read off the text once, rather than once per player.
        var hasLateral: Bool
        /// A ball fumbled rather than muffed: a muff is not a fumble.
        var hasFumble: Bool
        var isBlockedPunt: Bool
        var isBlockedExtraPoint: Bool
        /// Who was sacked, on a sack in the end zone parsed as the safety it scored.
        var sackedInEndZone: String?

        var isSack: Bool { summary.kind == .sack || sackedInEndZone != nil }

        init(play: Play, summary: PlaySummary, isRepeatedTry: Bool) {
            self.play = play
            self.summary = summary
            self.isRepeatedTry = isRepeatedTry
            let text = play.text
            hasLateral = text.range(of: "lateral", options: .caseInsensitive) != nil
            hasFumble = text.contains("FUMBLES") && !text.contains("MUFFS")
            isBlockedPunt = summary.kind == .punt && text.contains("punt is BLOCKED")
            isBlockedExtraPoint = text.contains("extra point is Blocked")
            sackedInEndZone = summary.kind == .safety ? Rx.sackedPasser(in: text) : nil
        }
    }

    private let snaps: [Snap]
    private let teams: [(id: String, abbreviation: String)]
    /// Normalized surname → every first-name prefix the game's play text uses with it.
    private let initialsBySurname: [String: Set<String>]

    /// `parse` is how a play's text is read, so a caller scoring the same feed over and
    /// over can hand back summaries it already has.
    public init(detail: GameDetail, game: Game?,
                parse: (Play) -> PlaySummary = { PlaySummary.parse($0.text) }) {
        // Drives arrive newest first and plays within a drive oldest first.
        let plays = detail.drives.reversed().flatMap(\.plays)
            .filter { $0.kind != .administrative && !$0.text.isEmpty }

        var snaps: [Snap] = []
        var lastTouchdownHadTry = true
        for play in plays {
            let summary = parse(play)
            var repeated = false
            switch summary.kind {
            case .extraPoint, .twoPointConversion:
                // ESPN posts the kick as its own play while the touchdown's text may
                // already end with it; counted once, wherever it appears first.
                repeated = lastTouchdownHadTry
                lastTouchdownHadTry = true
            default:
                if summary.touchdown != nil || play.scoreKind == .touchdown {
                    lastTouchdownHadTry = summary.tryResult != nil
                }
            }
            snaps.append(Snap(play: play, summary: summary, isRepeatedTry: repeated))
        }
        self.snaps = snaps
        self.teams = game.map { [($0.home.id, $0.home.abbreviation), ($0.away.id, $0.away.abbreviation)] } ?? []

        var initials: [String: Set<String>] = [:]
        for play in plays {
            for token in PlayAttribution.names(in: play.text) {
                initials[PlayAttribution.normalize(token.surname), default: []]
                    .insert(token.initial.lowercased())
            }
        }
        self.initialsBySurname = initials
    }

    /// The player's stat line for every play of the game, oldest first.
    public func lines(for player: RosterPlayer) -> [FantasyPlayLine] {
        let matcher = NameMatcher(player: player, initialsBySurname: initialsBySurname)
        var totals: [Int: Int] = [:]
        return snaps.map { snap in
            if snap.summary.kind == .underReview {
                return FantasyPlayLine(play: snap.play, stats: FantasyStatLine(), isUnderReview: true)
            }
            guard !snap.isRepeatedTry, snap.summary.kind != .noPlay else {
                return FantasyPlayLine(play: snap.play, stats: FantasyStatLine())
            }
            var stats = player.position == .defense
                ? defenseStats(snap, team: player.proTeamID.map(String.init))
                : playerStats(snap, matcher: matcher)
            Self.addCumulative(to: &stats, totals: &totals)
            return FantasyPlayLine(play: snap.play, stats: stats)
        }
    }

    // MARK: - Players

    private func playerStats(_ snap: Snap, matcher: NameMatcher) -> FantasyStatLine {
        let play = snap.summary
        var line = FantasyStatLine()
        let offense = snap.play.start.teamID
        let isKick = play.kind == .punt || play.kind == .kickoff
        // Who had the ball. The kicking team on a kick, so a returner is the other side.
        let onOffense = matcher.isOnTeam(offense)
        let onReturnTeam = offense == nil || !onOffense

        kickingStats(play, matcher: matcher, into: &line)

        guard !snap.hasLateral else { return line }

        let yards = Double(play.yards ?? 0)
        switch play.kind {
        case .pass where onOffense:
            let isTouchdown = play.touchdown == .pass
            let distance = play.yards ?? 0
            if matcher.isHim(play.passer) {
                line.add(FantasyStat.passAttempts)
                line.add(FantasyStat.passCompletions)
                line.add(FantasyStat.passingYards, yards)
                if isTouchdown {
                    line.add(FantasyStat.passingTouchdowns)
                    if distance >= 40 { line.add(FantasyStat.passingTouchdown40Plus) }
                    if distance >= 50 { line.add(FantasyStat.passingTouchdown50Plus) }
                }
            }
            if matcher.isHim(play.receiver) {
                line.add(FantasyStat.receptionsCounted)
                line.add(FantasyStat.receptions)
                line.add(FantasyStat.targets)
                line.add(FantasyStat.receivingYards, yards)
                if isTouchdown {
                    line.add(FantasyStat.receivingTouchdowns)
                    if distance >= 40 { line.add(FantasyStat.receivingTouchdown40Plus) }
                    if distance >= 50 { line.add(FantasyStat.receivingTouchdown50Plus) }
                }
            }
        case .incompletePass where onOffense, .interception where onOffense:
            if matcher.isHim(play.passer) {
                line.add(FantasyStat.passAttempts)
                line.add(FantasyStat.passIncompletions)
                if play.kind == .interception { line.add(FantasyStat.interceptionsThrown) }
            }
            if matcher.isHim(play.receiver) { line.add(FantasyStat.targets) }
        case .sack where onOffense:
            if matcher.isHim(play.passer) { line.add(FantasyStat.timesSacked) }
        case .safety where onOffense:
            if matcher.isHim(snap.sackedInEndZone) { line.add(FantasyStat.timesSacked) }
        case .rush where onOffense:
            if matcher.isHim(play.rusher) {
                line.add(FantasyStat.rushAttempts)
                line.add(FantasyStat.rushingYards, yards)
                if play.touchdown == .rush {
                    let distance = play.yards ?? 0
                    line.add(FantasyStat.rushingTouchdowns)
                    if distance >= 40 { line.add(FantasyStat.rushingTouchdown40Plus) }
                    if distance >= 50 { line.add(FantasyStat.rushingTouchdown50Plus) }
                }
            }
        default:
            break
        }

        // A return touchdown by an offensive player, on the side that did not kick.
        if onReturnTeam, matcher.isHim(play.scorer) {
            switch play.touchdown {
            case .kickoffReturn?: line.add(FantasyStat.kickoffReturnTouchdowns)
            case .puntReturn?: line.add(FantasyStat.puntReturnTouchdowns)
            default: break
            }
        }
        if play.touchdown == .fumbleRecovery, play.takeaway == nil, matcher.isHim(play.scorer) {
            line.add(FantasyStat.fumbleRecoveredForTouchdown)
        }

        // A muff is not a fumble, and a loose ball fumbled back and forth names nobody.
        if snap.hasFumble, matcher.isHim(play.fumbledBy),
           isKick ? onReturnTeam : onOffense {
            line.add(FantasyStat.fumbles)
            if play.takeaway == .fumble { line.add(FantasyStat.fumblesLost) }
        }

        twoPointStats(play, matcher: matcher, into: &line)
        return line
    }

    private func kickingStats(_ play: PlaySummary, matcher: NameMatcher, into line: inout FantasyStatLine) {
        if case .fieldGoal(let result) = play.kind, matcher.isHim(play.kicker) {
            let made = result == .good
            line.add(FantasyStat.fieldGoalsAttempted)
            line.add(made ? FantasyStat.fieldGoalsMade : FantasyStat.fieldGoalsMissed)
            if let distance = play.yards {
                let buckets: [(Bool, Int, Int, Int)] = [
                    (distance < 40, FantasyStat.fieldGoalsMadeUnder40,
                     FantasyStat.fieldGoalsAttemptedUnder40, FantasyStat.fieldGoalsMissedUnder40),
                    ((40..<50).contains(distance), FantasyStat.fieldGoalsMade40To49,
                     FantasyStat.fieldGoalsAttempted40To49, FantasyStat.fieldGoalsMissed40To49),
                    (distance >= 50, FantasyStat.fieldGoalsMade50Plus,
                     FantasyStat.fieldGoalsAttempted50Plus, FantasyStat.fieldGoalsMissed50Plus),
                    ((50..<60).contains(distance), FantasyStat.fieldGoalsMade50To59,
                     FantasyStat.fieldGoalsAttempted50To59, FantasyStat.fieldGoalsMissed50To59),
                    (distance >= 60, FantasyStat.fieldGoalsMade60Plus,
                     FantasyStat.fieldGoalsAttempted60Plus, FantasyStat.fieldGoalsMissed60Plus),
                ]
                for (applies, madeStat, attemptStat, missStat) in buckets where applies {
                    line.add(attemptStat)
                    line.add(made ? madeStat : missStat)
                }
            }
        }

        let kicker = play.kind == .extraPoint(good: true) || play.kind == .extraPoint(good: false)
            ? play.kicker : play.tryKicker
        guard matcher.isHim(kicker) else { return }
        switch play.tryResult {
        case .extraPointGood?:
            line.add(FantasyStat.extraPointsAttempted)
            line.add(FantasyStat.extraPointsMade)
        case .extraPointMissed?:
            line.add(FantasyStat.extraPointsAttempted)
            line.add(FantasyStat.extraPointsMissed)
        default:
            break
        }
    }

    private func twoPointStats(_ play: PlaySummary, matcher: NameMatcher, into line: inout FantasyStatLine) {
        guard play.tryResult == .twoPointGood else { return }
        let standalone = play.kind == .twoPointConversion(good: true)
        if matcher.isHim(standalone ? play.passer : play.tryPasser) {
            line.add(FantasyStat.passingTwoPointConversions)
        }
        if matcher.isHim(standalone ? play.receiver : play.tryReceiver) {
            line.add(FantasyStat.receivingTwoPointConversions)
        }
        if matcher.isHim(standalone ? play.rusher : play.tryRusher) {
            line.add(FantasyStat.rushingTwoPointConversions)
        }
    }

    // MARK: - Team defense

    /// A team defense is never named, so it is credited for what its side did: a sack
    /// or a pick against the other team's offense, a ball recovered, a kick blocked, a
    /// safety, a return touchdown.
    private func defenseStats(_ snap: Snap, team: String?) -> FantasyStatLine {
        var line = FantasyStatLine()
        guard let team, let offense = snap.play.start.teamID else { return line }
        let play = snap.summary
        let isDefending = offense != team
        // Who came away with a loose ball, by the abbreviation the text gives; without
        // one, on a scrimmage play it can only be the defense.
        let isKick = play.kind == .punt || play.kind == .kickoff || play.kind.isFieldGoal
        let recoveredByUs: Bool = {
            if let abbreviation = play.recoveringTeam, let id = teamID(textAbbreviation: abbreviation) {
                return id == team
            }
            return isDefending && !isKick
        }()

        if isDefending, snap.isSack { line.add(FantasyStat.defensiveSacks) }
        if isDefending, play.kind == .interception { line.add(FantasyStat.defensiveInterceptions) }
        if (play.takeaway == .fumble || play.takeaway == .muffedKick), recoveredByUs {
            line.add(FantasyStat.defensiveFumbleRecoveries)
        }
        if isDefending, play.kind == .safety || snap.play.scoreKind == .safety {
            line.add(FantasyStat.defensiveSafeties)
        }
        if isDefending, isBlocked(snap) { line.add(FantasyStat.defensiveBlockedKicks) }

        switch play.touchdown {
        case .interceptionReturn? where isDefending:
            line.add(FantasyStat.interceptionReturnTouchdowns)
        case .fumbleReturn? where recoveredByUs, .fumbleRecovery? where play.takeaway != nil && recoveredByUs:
            line.add(FantasyStat.fumbleReturnTouchdowns)
        case .puntReturn? where isDefending:
            line.add(FantasyStat.puntReturnTouchdowns)
        case .kickoffReturn? where isDefending:
            line.add(FantasyStat.kickoffReturnTouchdowns)
        case .blockedKickReturn? where isDefending:
            line.add(FantasyStat.blockedKickReturnTouchdowns)
        default:
            break
        }
        return line
    }

    private func isBlocked(_ snap: Snap) -> Bool {
        let play = snap.summary
        if play.kind == .fieldGoal(.blocked) || play.takeaway == .blockedKick { return true }
        if snap.isBlockedPunt { return true }
        // An extra point after the offense's own touchdown, kicked by the offense; a sack
        // in the end zone is parsed as the safety it scored, and is a sack as well.
        return play.touchdown != nil && play.takeaway == nil && snap.isBlockedExtraPoint
    }

    private func teamID(textAbbreviation: String) -> String? {
        let mapped = PlaySummary.scoreboardAbbreviation(textAbbreviation)
        return teams.first { $0.abbreviation == mapped || $0.abbreviation == textAbbreviation }?.id
    }

    // MARK: - Game totals

    /// Yardage chunks and milestones are worked out from the game total, so a play is
    /// credited with whatever its yards moved them by — usually nothing, a point when it
    /// crosses the line. A milestone can move both ways: from 300–399 into 400+.
    private static func addCumulative(to line: inout FantasyStatLine, totals: inout [Int: Int]) {
        for total in [FantasyStat.passingYards, FantasyStat.rushingYards, FantasyStat.receivingYards] {
            let gained = Int(line[total])
            guard gained != 0 else { continue }
            let before = totals[total] ?? 0
            let after = before + gained
            totals[total] = after
            for chunk in FantasyStat.yardageChunks where chunk.total == total {
                let moved = max(after, 0) / chunk.per - max(before, 0) / chunk.per
                if moved != 0 { line.add(chunk.stat, Double(moved)) }
            }
            for milestone in FantasyStat.milestones where milestone.total == total {
                let moved = (milestone.range.contains(after) ? 1 : 0) - (milestone.range.contains(before) ? 1 : 0)
                if moved != 0 { line.add(milestone.stat, Double(moved)) }
            }
        }
    }
}

// MARK: - Names

/// Whether a name in a play is this player.
///
/// The same rule as `PlayAttribution`'s: the initial must start his first name and the
/// surname match without the `Jr.` or `III` rosters keep. Play text also uses longer
/// forms to tell players apart — `Bi.Robinson` for Bijan beside `B.Robinson` for Brian —
/// so when one game's text has more than one form that would fit him, only the longest
/// is taken as his. Full names, from ESPN's scoring-summary phrasing, are compared whole.
private struct NameMatcher {
    let player: RosterPlayer
    let first: String
    let surname: String
    /// The only first-name prefix that is his, when the game's text uses more than one.
    let initial: String?

    init(player: RosterPlayer, initialsBySurname: [String: Set<String>]) {
        let first = player.firstName.lowercased()
        let surname = PlayAttribution.normalize(PlayAttribution.baseSurname(player.lastName))
        let fitting = (initialsBySurname[surname] ?? []).filter { first.hasPrefix($0) }
        self.player = player
        self.first = first
        self.surname = surname
        initial = fitting.count > 1 ? fitting.max { $0.count < $1.count } : nil
    }

    func isHim(_ shown: String?) -> Bool {
        guard let shown, !shown.isEmpty else { return false }
        guard let dot = shown.range(of: ". "),
              shown.distance(from: shown.startIndex, to: dot.lowerBound) <= 3
        else { return PlaySummary.name(shown, matchesFirst: player.firstName, last: player.lastName) }
        let shownInitial = shown[..<dot.lowerBound].lowercased()
        guard first.hasPrefix(shownInitial), initial.map({ $0 == shownInitial }) ?? true else { return false }
        return PlayAttribution.normalize(String(shown[dot.upperBound...])) == surname
    }

    func isOnTeam(_ teamID: String?) -> Bool {
        guard let teamID, let mine = player.proTeamID else { return true }
        return teamID == String(mine)
    }
}

private enum Rx {
    static let sacked = try! NSRegularExpression(
        pattern: "(?<![A-Za-z.])([A-Z][a-z]{0,2}\\.(?:St\\. |Van )?[A-Z][A-Za-z'\\-]*[A-Za-z]) sacked"
    )

    /// "D.Maye sacked in End Zone…" → "D. Maye".
    static func sackedPasser(in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = sacked.firstMatch(in: text, range: range),
              let name = Range(match.range(at: 1), in: text) else { return nil }
        return PlaySummary.display(String(text[name]))
    }
}

private extension PlaySummary.Kind {
    var isFieldGoal: Bool {
        if case .fieldGoal = self { return true }
        return false
    }
}
