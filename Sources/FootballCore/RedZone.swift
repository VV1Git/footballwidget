import Foundation

/// RedZone features one game out of everything live, the way the TV channel whips
/// around the league. It is all worked out from the scoreboard, so following every game
/// at once costs no play-by-play requests.

// MARK: - Field position

public enum FieldPosition {

    /// Yards from the line of scrimmage to the goal the offense attacks. Parses situation.possessionText
    /// ("BUF 12", "50") against game.teamWithPossession; text abbreviations via PlaySummary.scoreboardAbbreviation.
    /// Own side → 100 - n, opponent side → n, "50" → 50. Nil with no possession team, unparseable text, or down outside 1...4.
    ///
    /// The down check matters: ESPN flags the red zone with nobody in possession while a
    /// try or field goal is lined up, and those snaps are not a drive in progress.
    public static func yardsToGoal(_ situation: Situation, in game: Game) -> Int? {
        guard let down = situation.down, (1...4).contains(down),
              let offense = game.team(id: situation.possessionTeamID),
              let text = situation.possessionText?.trimmingCharacters(in: .whitespaces),
              !text.isEmpty
        else { return nil }

        let pieces = text.split(separator: " ").map(String.init)
        guard let yard = pieces.last.flatMap({ Int($0) }), (1...50).contains(yard) else { return nil }
        if pieces.count == 1 { return yard == 50 ? 50 : nil }

        let side = pieces.dropLast().joined(separator: " ")
        let defense = offense.id == game.home.id ? game.away : game.home
        if names(offense, side) { return 100 - yard }
        if names(defense, side) { return yard }
        return nil
    }

    /// Yards to goal of the first-down marker (ytg - distance), nil when goal-to-go (distance >= ytg) or unknown.
    public static func firstDownYardsToGoal(_ situation: Situation, in game: Game) -> Int? {
        guard let ytg = yardsToGoal(situation, in: game),
              let distance = situation.distance, distance > 0, distance < ytg,
              !textSaysGoal(situation)
        else { return nil }
        return ytg - distance
    }

    /// ESPN writes "1st & Goal" whenever the marker would be past the goal line, which
    /// is the one case the distance alone can get wrong after a penalty.
    static func isGoalToGo(_ situation: Situation, yardsToGoal: Int?) -> Bool {
        if textSaysGoal(situation) { return true }
        guard let ytg = yardsToGoal, let distance = situation.distance else { return false }
        return distance >= ytg
    }

    static func textSaysGoal(_ situation: Situation) -> Bool {
        [situation.shortDownDistance, situation.downDistanceText]
            .contains { $0?.contains("Goal") == true }
    }

    /// Spot text can use play-text abbreviations ("BLT 30") as well as scoreboard ones.
    private static func names(_ team: TeamSide, _ abbreviation: String) -> Bool {
        team.abbreviation == abbreviation
            || team.abbreviation == PlaySummary.scoreboardAbbreviation(abbreviation)
    }
}

// MARK: - Fantasy leverage

/// How much the user's fantasy matchup has riding on the snap about to happen.
public struct FantasyLeverage: Hashable, Sendable {
    public var mineOnOffense: Int
    public var theirsOnOffense: Int
    public var myDefenseOnField: Bool
    /// Display name of the most relevant player, e.g. "T. Kelce".
    public var leadName: String?
    public var leadIsMine: Bool

    public static let none = FantasyLeverage()

    public init(mineOnOffense: Int = 0, theirsOnOffense: Int = 0, myDefenseOnField: Bool = false,
                leadName: String? = nil, leadIsMine: Bool = false) {
        self.mineOnOffense = mineOnOffense
        self.theirsOnOffense = theirsOnOffense
        self.myDefenseOnField = myDefenseOnField
        self.leadName = leadName
        self.leadIsMine = leadIsMine
    }

    /// From starters in this game (FantasyStore.players(inGame:) shape). Counts QB/RB/WR/TE/K whose proTeamID == possession team id;
    /// myDefenseOnField = a .defense player that isMine on the team WITHOUT the ball. Mine wins the lead name; name format "F. Last" (use PlayAttribution.baseSurname for the last name).
    ///
    /// The lead is the first qualifying player in the order given, which for
    /// `players(inGame:)` is the biggest scorer so far.
    public init(players: [(player: RosterPlayer, isMine: Bool)], game: Game) {
        guard let possession = game.situation?.possessionTeamID,
              let offense = game.team(id: possession), let offenseID = Int(offense.id)
        else {
            self.init()
            return
        }
        let defenseID = Int(offense.id == game.home.id ? game.away.id : game.home.id)
        let skill: Set<FantasyPosition> = [.quarterback, .runningBack, .wideReceiver, .tightEnd, .kicker]

        let onOffense = players.filter { skill.contains($0.player.position) && $0.player.proTeamID == offenseID }
        let mine = onOffense.filter(\.isMine)
        let theirs = onOffense.filter { !$0.isMine }
        let lead = mine.first ?? theirs.first

        self.init(
            mineOnOffense: mine.count,
            theirsOnOffense: theirs.count,
            myDefenseOnField: defenseID != nil && players.contains {
                $0.isMine && $0.player.position == .defense && $0.player.proTeamID == defenseID
            },
            leadName: lead.map { Self.displayName($0.player) },
            leadIsMine: lead?.isMine ?? false
        )
    }

    /// "T. Kelce" — short enough for the reason line.
    static func displayName(_ player: RosterPlayer) -> String {
        let surname = PlayAttribution.baseSurname(player.lastName)
        guard let initial = player.firstName.first else { return surname }
        return "\(initial). \(surname)"
    }
}

// MARK: - Ranking

public struct RankedGame: Identifiable, Hashable, Sendable {
    /// Game id.
    public let id: String
    public var score: Double
    public var reason: String
    /// Live and not at a break.
    public var inPlay: Bool
    /// The ball is inside the 20.
    public var inRedZone: Bool

    public init(id: String, score: Double, reason: String, inPlay: Bool, inRedZone: Bool) {
        self.id = id
        self.score = score
        self.reason = reason
        self.inPlay = inPlay
        self.inRedZone = inRedZone
    }
}

public enum RedZoneRanker {

    /// Reasons are shown on one line beside the featured game; past this the clock note
    /// is left off rather than cut.
    static let reasonLimit = 34

    /// How worth watching a game is right now. Nil for games that are not live.
    ///
    /// In play: `(10 + field + goalToGo + down + clutch + twoMinute + recent + fresh) × blowout
    /// + fantasy`, where `fresh` rewards a snap that has just happened (`lastSnapAge`).
    /// A break scores far below any snap, `2 + 0.25 × fantasy`, so a game at halftime is
    /// only featured when nothing else is on.
    public static func rank(_ game: Game, leverage: FantasyLeverage = .none, recent: Moment? = nil,
                            lastSnapAge: TimeInterval? = nil, now: Date) -> RankedGame? {
        guard game.isLive else { return nil }
        let situation = game.situation
        let ytg = situation.flatMap { FieldPosition.yardsToGoal($0, in: game) }
        let inRedZone = ytg.map { $0 <= 20 } ?? false

        if let pause = breakReason(game) {
            return RankedGame(id: game.id, score: 2 + 0.25 * fantasyTerm(leverage, insideTwenty: false),
                              reason: pause, inPlay: false, inRedZone: inRedZone)
        }

        let offense = game.team(id: situation?.possessionTeamID)
        let seconds = AlertRules.seconds(game.displayClock)
        let margin = game.scoreMargin

        var field = 0.0
        if let ytg {
            if ytg <= 20 { field = 26 + 0.7 * Double(20 - ytg) }
            else if ytg <= 40 { field = 0.6 * Double(40 - ytg) }
        }
        let goalToGo = ytg != nil && situation.map { FieldPosition.isGoalToGo($0, yardsToGoal: ytg) } == true

        // A fourth down deep in your own end is a punt, not a moment.
        var down = 0.0
        if offense != nil, let situation {
            switch situation.down {
            case 3?: down = 6
            case 4? where (ytg.map { $0 <= 45 } ?? false) || (situation.distance.map { $0 <= 2 } ?? false):
                down = 10
            default: break
            }
        }

        var clutch = 0.0
        if game.period >= 4, margin <= 8 {
            clutch = game.period == 4
                ? 10 + 20 * (1 - Double(min(seconds ?? 600, 600)) / 600)
                : 30
            if margin <= 3 { clutch += 4 }
        }

        let twoMinute = game.period == 2 && (seconds.map { $0 <= 120 } ?? false) ? 6.0 : 0

        // Measured from the feed rather than `lastPlayWasScoring`, which stays set through
        // the kickoff and the snaps after it.
        var recentBonus = 0.0
        if let recent, recent.gameID == game.id, recent.kind == .scoring || recent.kind == .turnover {
            let age = max(0, now.timeIntervalSince(recent.at))
            recentBonus = 15 * max(0, 1 - age / 90)
        }

        var blowout = 1.0
        if game.period >= 3 {
            if margin >= 25 { blowout = 0.3 } else if margin >= 17 { blowout = 0.5 }
        }

        let fantasy = fantasyTerm(leverage, insideTwenty: inRedZone)
        let fieldTerm = field + (goalToGo ? 4 : 0)
        let fresh = freshness(lastSnapAge)
        let score = (10 + fieldTerm + down + clutch + twoMinute + recentBonus + fresh) * blowout + fantasy

        // Wording.
        let shortDown = situation.flatMap { shortDownText($0, goalToGo: goalToGo) }
        let spotDown: String? = {
            guard shortDown != nil, let text = situation?.downDistanceText,
                  !text.trimmingCharacters(in: .whitespaces).isEmpty else { return shortDown }
            return text
        }()
        let generic: String
        if let offense {
            generic = spotDown.map { "\(offense.abbreviation) ball · \($0)" } ?? "\(offense.abbreviation) ball"
        } else {
            generic = RedZoneText.clock(game) ?? "Live"
        }
        let clockLeft = game.displayClock.isEmpty ? nil : "\(game.displayClock) left"

        var fieldText = generic
        if let ytg, let shortDown, ytg <= 20 {
            fieldText = ytg <= 5 && goalToGo ? "Goal line · \(shortDown)" : "Red zone · \(shortDown)"
        }
        let clutchText: String
        if game.period > 4 {
            clutchText = "Overtime"
        } else {
            let lead = margin == 0 ? "Tied" : "One-score game"
            clutchText = clockLeft.map { "\(lead), \($0)" } ?? lead
        }
        let fantasyText: String
        if let name = leverage.leadName {
            fantasyText = leverage.leadIsMine ? "Your \(name) on offense" : "Opp's \(name) on offense"
        } else if leverage.mineOnOffense > 0 {
            fantasyText = "Your starter on offense"
        } else if leverage.theirsOnOffense > 0 {
            fantasyText = "Opp's starter on offense"
        } else {
            fantasyText = "Your D/ST on the field"
        }

        // Earlier entries win ties.
        let terms: [(value: Double, text: String, isClutch: Bool)] = [
            (fieldTerm * blowout, fieldText, false),
            (down * blowout, spotDown ?? generic, false),
            (clutch * blowout, clutchText, true),
            (recentBonus * blowout, recent?.title ?? generic, false),
            (fantasy, fantasyText, false),
            (twoMinute * blowout, offense.map { "Two-minute drill · \($0.abbreviation) ball" } ?? "Two-minute drill", false),
        ]
        var reason = generic
        var reasonIsClutch = false
        var largest = 0.0
        for term in terms where term.value > largest {
            largest = term.value
            reason = term.text
            reasonIsClutch = term.isClutch
        }
        if clutch > 0, !reasonIsClutch, let clockLeft {
            let longer = "\(reason) · \(clockLeft)"
            if longer.count <= reasonLimit { reason = longer }
        }

        return RankedGame(id: game.id, score: score, reason: reason, inPlay: true, inRedZone: inRedZone)
    }

    /// Which game to feature, given the one featured now.
    ///
    /// A challenger has to beat the featured game by a clear margin — 15 while it is
    /// inside the 20, 8 otherwise — so two games trading small edges do not swap every
    /// poll. Real events clear the bar on their own: reaching the red zone is worth 26, a
    /// score 15. A featured game that has ended, dropped off, or gone to a break while
    /// another is in play gives way at once.
    /// Worth of a snap that has just happened: 25 the moment it lands, gone after 20
    /// seconds.
    ///
    /// Without it the ranker scored only the situation, and most snaps happen between the
    /// 20s where every game scores about the same — so whichever game held the spotlight
    /// kept it, the switching margin never being beaten, and the window sat on one game
    /// all afternoon. With it, each snap anywhere pulls the spotlight to that game, which
    /// across a full slate means roughly a new play every ten seconds, as RedZone does. A
    /// drive inside the 20 still outranks a fresh snap at midfield between its own plays.
    public static let freshSnapBonus = 25.0
    public static let freshSnapWindow: TimeInterval = 20

    static func freshness(_ age: TimeInterval?) -> Double {
        guard let age, age >= 0 else { return 0 }
        return freshSnapBonus * max(0, 1 - age / freshSnapWindow)
    }

    /// The least time a game stays featured once it gets the spotlight, so a play can be
    /// read before the window cuts away to the next snap somewhere else.
    public static let minimumDwell: TimeInterval = 8

    /// `heldFor` is how long `current` has been featured.
    public static func spotlight(_ ranked: [RankedGame], current: String?,
                                 favoriteGameIDs: Set<String> = [],
                                 heldFor: TimeInterval? = nil) -> String? {
        if let current, let heldFor, heldFor < minimumDwell,
           ranked.contains(where: { $0.id == current && $0.inPlay }) {
            return current
        }
        let inPlay = ranked.filter(\.inPlay)
        let pool = inPlay.isEmpty ? ranked : inPlay
        guard var best = pool.first else { return nil }
        for game in pool.dropFirst() where prefers(game, over: best, current: current, favorites: favoriteGameIDs) {
            best = game
        }

        guard let current, let held = ranked.first(where: { $0.id == current }) else { return best.id }
        if best.id == held.id { return held.id }
        if !held.inPlay && !inPlay.isEmpty { return best.id }
        let margin: Double = held.inRedZone ? 15 : 8
        return best.score >= held.score + margin ? best.id : held.id
    }

    /// Higher score, then the featured game, then a favourite team's, then the lower id.
    static func prefers(_ a: RankedGame, over b: RankedGame, current: String?, favorites: Set<String>) -> Bool {
        if a.score != b.score { return a.score > b.score }
        if a.id == current || b.id == current { return a.id == current }
        let aFavorite = favorites.contains(a.id), bFavorite = favorites.contains(b.id)
        if aFavorite != bFavorite { return aFavorite }
        return a.id.compare(b.id, options: .numeric) == .orderedAscending
    }

    /// "Halftime", "End of Q1", "Official timeout", "MIN timeout"; nil while the ball can
    /// be snapped.
    ///
    /// A stoppage counts as a break too. A game sat in a TV timeout kept the spotlight
    /// because nothing else outranked it by the switching margin, and showed an empty
    /// down and distance — ESPN drops possession during one — with "Official Timeout at
    /// 07:08" as the last play. Now any game with the ball live takes over at once, and
    /// the stopped game comes back when play resumes if it still matters most.
    static func breakReason(_ game: Game) -> String? {
        if game.phase == .halftime { return "Halftime" }
        guard game.phase == .live else { return nil }
        if game.period == 1 || game.period == 3, game.displayClock == "0:00" {
            return "End of Q\(game.period)"
        }
        switch game.situation?.lastPlayTypeID {
        case "74"?: return "Official timeout"
        case "75"?: return "Two-minute warning"
        case "21"?:
            let text = game.situation?.lastPlayText ?? ""
            if let range = text.range(of: "by [A-Z]{2,4}", options: .regularExpression) {
                let team = PlaySummary.scoreboardAbbreviation(String(text[range].dropFirst(3)))
                return "\(team) timeout"
            }
            return "Timeout"
        default: return nil
        }
    }

    static func fantasyTerm(_ leverage: FantasyLeverage, insideTwenty: Bool) -> Double {
        var term = min(15, 6 * Double(leverage.mineOnOffense) + 3 * Double(leverage.theirsOnOffense))
        if insideTwenty { term *= 1.5 }
        if leverage.myDefenseOnField { term += 3 }
        return term
    }

    /// "3rd & 4", "1st & Goal". ESPN's own text when it sent some.
    static func shortDownText(_ situation: Situation, goalToGo: Bool) -> String? {
        guard let down = situation.down, (1...4).contains(down) else { return nil }
        if let text = situation.shortDownDistance?.trimmingCharacters(in: .whitespaces),
           text.first?.isNumber == true {
            return text
        }
        let ordinal = RedZoneText.ordinal(down)
        if goalToGo { return "\(ordinal) & Goal" }
        return situation.distance.map { "\(ordinal) & \($0)" } ?? ordinal
    }
}

// MARK: - Text

public enum RedZoneText {

    /// The last play without what the spotlight has no room for: formation, snapper and
    /// holder credits, "reported in as eligible".
    public static func lastPlay(_ text: String) -> String {
        FantasyAlertRules.condensed(text)
    }

    /// The one-line pill: "KC 17-14 BUF · 2&4 BUF 12 · Q4 2:11". The away team is always
    /// first, so the line does not flip around when the lead changes.
    /// Halftime: "KC 17-14 BUF · HALF"; with no situation, just the score and clock.
    public static func pill(_ game: Game) -> String {
        var parts = ["\(game.away.abbreviation) \(game.away.score)-\(game.home.score) \(game.home.abbreviation)"]
        if game.phase == .live, let situation = game.situation, let down = compactDown(situation) {
            if let spot = situation.possessionText?.trimmingCharacters(in: .whitespaces), !spot.isEmpty {
                parts.append("\(down) \(spot)")
            } else {
                parts.append(down)
            }
        }
        if let clock = clock(game) { parts.append(clock) }
        return parts.joined(separator: " · ")
    }

    /// "2&4", "3&G" (goal-to-go), nil if no down.
    public static func compactDown(_ situation: Situation) -> String? {
        guard let down = situation.down, (1...4).contains(down) else { return nil }
        if FieldPosition.textSaysGoal(situation) { return "\(down)&G" }
        if let distance = situation.distance ?? parsedDistance(situation.shortDownDistance) {
            return "\(down)&\(distance)"
        }
        return ordinal(down)
    }

    /// "Q3 4:12", "HALF", "FINAL", "OT 3:40"; nil before kickoff.
    static func clock(_ game: Game) -> String? {
        let period = game.periodLabel
        guard !period.isEmpty else { return nil }
        if game.phase == .final || game.phase == .halftime || game.displayClock.isEmpty { return period }
        return "\(period) \(game.displayClock)"
    }

    static func ordinal(_ down: Int) -> String {
        switch down {
        case 1: return "1st"
        case 2: return "2nd"
        case 3: return "3rd"
        default: return "\(down)th"
        }
    }

    /// The number after "&" in "3rd & 4".
    private static func parsedDistance(_ text: String?) -> Int? {
        guard let text, let amp = text.firstIndex(of: "&") else { return nil }
        return Int(text[text.index(after: amp)...].trimmingCharacters(in: .whitespaces))
    }
}
