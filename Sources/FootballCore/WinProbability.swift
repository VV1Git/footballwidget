import Foundation

/// Your chance of winning this week's fantasy matchup, as ESPN's FantasyCast shows it
/// under "Chance to Win".
///
/// ## Where the number comes from
///
/// In order of preference:
///
/// 1. **A settled result.** ESPN has declared a winner, or every starter on both sides
///    has finished his game. Nothing is left to estimate, so it is 100%, 0%, or 50% for
///    an exact tie.
/// 2. **ESPN's own number.** The league endpoint's `mMatchupScore` view carries
///    `winProbability` on each side of the matchup in progress. It is the number ESPN
///    shows, so the widget and the ESPN app agree. This was checked against FantasyCast
///    during a live week rather than assumed.
/// 3. **The model below**, only when ESPN sends no number. A finished season's schedule
///    has none, for example, and nothing says ESPN will always send one mid-week.
///
/// ## The model
///
/// Each side's expected final is the points already scored plus the projected points
/// still to come. A starter whose game has not started still owes his whole weekly
/// projection; one in progress owes the share of it matching the time left in his game;
/// one whose game is over owes nothing. The margin between the two expected finals is
/// treated as normally distributed, and the chance of winning is Φ(margin / σ).
///
/// σ comes from the projected points still to come on both rosters: each remaining
/// projected point carries a variance of `variancePerProjectedPoint`. Fantasy scoring
/// comes in lumps (a touchdown is six points at once), so the spread grows with how
/// much scoring is left rather than being fixed. As games finish that pool drains, σ
/// shrinks, and the probability converges on 0 or 1.
///
/// Assumptions worth knowing:
/// - Players are independent. A quarterback and his receiver rise and fall together,
///   and stacking them makes a lineup more volatile than this admits.
/// - A projection is used linearly through the game: half the game left, half the
///   projection left. ESPN's live projection is smarter about players who have already
///   blown past or fallen short of theirs.
/// - Game progress comes from the NFL scoreboard, so it assumes that feed is on the same
///   week as the fantasy league. A starter whose team has no game in the feed counts as
///   still to play, unless ESPN projects him for nothing (a bye).
/// - A starter still to play without a projection makes the whole estimate unknown.
///   No number is better than a made-up one.
public struct WinProbability: Sendable, Hashable {

    public enum Source: Sendable, Hashable {
        /// ESPN's own `winProbability`.
        case espn
        /// Estimated here from projections, because ESPN sent nothing.
        case model
        /// Nothing left to estimate: ESPN settled it, or every starter's game is over.
        case result
    }

    /// Your chance of winning, 0–1.
    public var mine: Double
    public var source: Source
    /// The expected finals behind the number: ESPN's live projected totals when it sends
    /// them, the model's otherwise. Nil once the result is settled.
    public var projectedMine: Double?
    public var projectedTheirs: Double?

    public init(mine: Double, source: Source,
                projectedMine: Double? = nil, projectedTheirs: Double? = nil) {
        self.mine = min(max(mine, 0), 1)
        self.source = source
        self.projectedMine = projectedMine
        self.projectedTheirs = projectedTheirs
    }

    public var theirs: Double { 1 - mine }
    public var isSettled: Bool { source == .result }

    /// Whole percentages, rounded once so the two sides always add up to 100.
    public var myPercent: Int { Int((mine * 100).rounded()) }
    public var theirPercent: Int { 100 - myPercent }

    /// "79%". While anything is left to play the ends read ">99%" and "<1%": a late
    /// field goal can still flip a matchup, and "100%" would say it cannot.
    public var myPercentText: String { Self.text(percent: myPercent, settled: isSettled) }
    public var theirPercentText: String { Self.text(percent: theirPercent, settled: isSettled) }

    static func text(percent: Int, settled: Bool) -> String {
        if !settled && percent >= 100 { return ">99%" }
        if !settled && percent <= 0 { return "<1%" }
        return "\(percent)%"
    }

    // MARK: - Estimating

    /// Variance, in points², carried by each projected point still to be scored.
    ///
    /// Fitted to ESPN rather than picked. Across 22 snapshots of live matchups in two
    /// real leagues, taken on the Sunday of week 1 in 2026 with games in progress, the
    /// σ implied by ESPN's `winProbability` worked out at 13–19 points² per remaining
    /// projected point wherever the margin was wide enough to read it, median 16. With
    /// that value the model came within three percentage points of ESPN's number on
    /// average, and within six at worst.
    public static let variancePerProjectedPoint = 16.0

    /// Scores closer than this are the same score. ESPN reports points to two decimals.
    static let tieTolerance = 0.005

    /// The best available chance of winning, or nil when there is no opponent or no
    /// honest way to put a number on it.
    ///
    /// - Parameter progress: where the NFL game of the team with this id has got to,
    ///   or nil if there is no such game in the feed.
    public static func estimate(
        for matchup: FantasyMatchup,
        progress: (Int) -> GameProgress?
    ) -> WinProbability? {
        guard let opponent = matchup.opponent else { return nil }

        if let outcome = matchup.outcome {
            switch outcome {
            case .won: return WinProbability(mine: 1, source: .result)
            case .lost: return WinProbability(mine: 0, source: .result)
            case .tied: return WinProbability(mine: 0.5, source: .result)
            }
        }

        // ESPN is slow to settle a week, so do not wait for it once the games are over.
        // An empty lineup proves nothing, though: that is a roster that did not load.
        let hasLineups = !matchup.mine.starters.isEmpty && !opponent.starters.isEmpty
        let starters = matchup.mine.starters + opponent.starters
        if hasLineups && !starters.contains(where: { isStillToPlay($0, progress) }) {
            let margin = matchup.margin
            let mine: Double = abs(margin) < tieTolerance ? 0.5 : (margin > 0 ? 1 : 0)
            return WinProbability(mine: mine, source: .result)
        }

        let forecast = forecast(for: matchup, progress: progress)
        // ESPN's "Proj Total" is what its app shows beside the number, so prefer it.
        var projectedMine = forecast?.expectedMine
        var projectedTheirs = forecast?.expectedTheirs
        if let espnMine = matchup.mine.projectedPoints, let espnTheirs = opponent.projectedPoints {
            projectedMine = espnMine
            projectedTheirs = espnTheirs
        }

        if let espn = matchup.espnWinProbability, espn.isFinite {
            return WinProbability(mine: espn, source: .espn,
                                  projectedMine: projectedMine, projectedTheirs: projectedTheirs)
        }
        guard let forecast else { return nil }
        return WinProbability(mine: forecast.probability, source: .model,
                              projectedMine: projectedMine, projectedTheirs: projectedTheirs)
    }

    /// The model's view of the matchup, before any preference for ESPN's number.
    struct Forecast: Hashable {
        var expectedMine: Double
        var expectedTheirs: Double
        /// Standard deviation of the final margin, in points.
        var sigma: Double
        var probability: Double

        var expectedMargin: Double { expectedMine - expectedTheirs }
    }

    static func forecast(for matchup: FantasyMatchup,
                         progress: (Int) -> GameProgress?) -> Forecast? {
        // A lineup with nobody in it is a roster that did not load, and projecting it
        // would hand the other side a certainty it has not earned.
        guard let opponent = matchup.opponent,
              !matchup.mine.starters.isEmpty, !opponent.starters.isEmpty,
              let mine = outlook(for: matchup.mine, progress: progress),
              let theirs = outlook(for: opponent, progress: progress)
        else { return nil }

        let variance = variancePerProjectedPoint * (mine.stillToCome + theirs.stillToCome)
        let sigma = variance.squareRoot()
        let margin = mine.expected - theirs.expected

        let probability: Double
        if sigma < 1e-9 {
            // Nothing projected is left, but some game is: the lead is all there is.
            probability = abs(margin) < tieTolerance ? 0.5 : (margin > 0 ? 1 : 0)
        } else {
            probability = normalCDF(margin / sigma)
        }
        return Forecast(expectedMine: mine.expected, expectedTheirs: theirs.expected,
                        sigma: sigma, probability: probability)
    }

    /// One side's expected final, and how many of those points are still to come.
    /// Nil when a starter who is still to play has no projection.
    static func outlook(for team: FantasyTeam,
                        progress: (Int) -> GameProgress?) -> (expected: Double, stillToCome: Double)? {
        var expectedStill = 0.0
        var stillToCome = 0.0
        for player in team.starters where isStillToPlay(player, progress) {
            guard let projection = player.projectedPoints, projection.isFinite else { return nil }
            let share = shareLeft(of: player, progress)
            expectedStill += projection * share
            // A defense can be projected below zero; it still cannot be less than certain.
            stillToCome += max(projection, 0) * share
        }
        return (team.points + expectedStill, stillToCome)
    }

    /// Whether this starter can still add points. Without a game to go on, a player is
    /// assumed to be still to play unless ESPN projects him for nothing, which is what
    /// it does for a bye.
    static func isStillToPlay(_ player: RosterPlayer, _ progress: (Int) -> GameProgress?) -> Bool {
        if let team = player.proTeamID, let state = progress(team) {
            return state != .finished
        }
        return player.projectedPoints != 0
    }

    static func shareLeft(of player: RosterPlayer, _ progress: (Int) -> GameProgress?) -> Double {
        guard let team = player.proTeamID, let state = progress(team) else { return 1 }
        return state.remaining
    }

    /// Φ, the standard normal CDF.
    static func normalCDF(_ z: Double) -> Double {
        0.5 * erfc(-z / 2.0.squareRoot())
    }
}

/// How far through his NFL game a fantasy starter is, as far as the win probability
/// cares.
public enum GameProgress: Sendable, Hashable {
    case notStarted
    /// `remaining` is the share of regulation still to be played, 0–1.
    case inProgress(remaining: Double)
    case finished

    /// Share of the game still to be played.
    public var remaining: Double {
        switch self {
        case .notStarted: return 1
        case .inProgress(let remaining): return min(max(remaining, 0), 1)
        case .finished: return 0
        }
    }

    static let regulationSeconds = 3600.0
    static let quarterSeconds = 900.0

    /// Reads progress off the scoreboard's period and clock. Overtime counts its clock
    /// against the length of regulation, so it is a small share rather than none: the
    /// game is not over and points are still possible. Nil when ESPN's status is one
    /// this cannot place.
    public init?(game: Game) {
        switch game.phase {
        case .pre:
            self = .notStarted
        case .final:
            self = .finished
        case .halftime:
            self = .inProgress(remaining: 0.5)
        case .unknown:
            return nil
        case .live:
            let period = max(game.period, 1)
            // A clock that will not parse is taken as the middle of the quarter.
            let clock = Self.seconds(in: game.displayClock) ?? Self.quarterSeconds / 2
            let left: Double
            if period <= 4 {
                left = Double(4 - period) * Self.quarterSeconds + min(clock, Self.quarterSeconds)
            } else {
                left = clock
            }
            self = .inProgress(remaining: left / Self.regulationSeconds)
        }
    }

    /// "12:39" → 759. A bare number of seconds is accepted too, rather than trusting
    /// the format never to change.
    static func seconds(in clock: String) -> Double? {
        let parts = clock.trimmingCharacters(in: .whitespaces).split(separator: ":")
        switch parts.count {
        case 1:
            return Double(parts[0])
        case 2:
            guard let minutes = Double(parts[0]), let seconds = Double(parts[1]) else { return nil }
            return minutes * 60 + seconds
        default:
            return nil
        }
    }
}
