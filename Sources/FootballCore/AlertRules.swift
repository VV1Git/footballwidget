import Foundation

/// Deciding *whether* to alert is separate from delivering one, so the rules can be
/// tested without posting notifications to anybody's screen.

/// What a game looked like at the last poll — just enough to tell what changed since.
public struct GameSnapshot: Sendable, Equatable {
    public var homeScore: Int
    public var awayScore: Int
    public var isRedZone: Bool
    public var possessionTeamID: String?
    public var lastPlayID: String?
    /// Kept so a change of possession on the next snap can be recognised as a turnover
    /// on downs; ESPN's `lastPlay` does not say which down it was run on.
    public var down: Int?
    /// "4th & 2", for the turnover-on-downs banner.
    public var shortDownDistance: String?
    public var period: Int?
    public var clock: String?
    /// The last play already on the board when the score last moved. Its text describes
    /// points that have been announced, so a later score change must not reuse it — the
    /// score can post a poll before the play that earned it.
    public var scoredPlayID: String?
    /// ESPN had only its `*** play under review ***` placeholder, so the play is worth
    /// looking at again once the ruling replaces it.
    public var lastPlayUnderReview: Bool

    public init(homeScore: Int, awayScore: Int, isRedZone: Bool,
                possessionTeamID: String?, lastPlayID: String?,
                down: Int? = nil, shortDownDistance: String? = nil,
                period: Int? = nil, clock: String? = nil,
                scoredPlayID: String? = nil, lastPlayUnderReview: Bool = false) {
        self.homeScore = homeScore
        self.awayScore = awayScore
        self.isRedZone = isRedZone
        self.possessionTeamID = possessionTeamID
        self.lastPlayID = lastPlayID
        self.down = down
        self.shortDownDistance = shortDownDistance
        self.period = period
        self.clock = clock
        self.scoredPlayID = scoredPlayID
        self.lastPlayUnderReview = lastPlayUnderReview
    }

    /// `previous` carries forward which play has already been credited with points. On a
    /// first sighting the score on the board already includes whatever the last play
    /// was worth, so that play counts as credited.
    public init(game: Game, previous: GameSnapshot? = nil) {
        let situation = game.situation
        let scoreMoved = previous.map {
            $0.homeScore != game.home.score || $0.awayScore != game.away.score
        } ?? true
        self.init(
            homeScore: game.home.score,
            awayScore: game.away.score,
            isRedZone: situation?.isRedZone ?? false,
            possessionTeamID: situation?.possessionTeamID,
            lastPlayID: situation?.lastPlayID,
            down: situation?.down,
            shortDownDistance: situation?.shortDownDistance,
            period: game.period,
            clock: game.displayClock,
            scoredPlayID: scoreMoved ? situation?.lastPlayID : previous?.scoredPlayID,
            lastPlayUnderReview: PlaySummary.parse(situation?.lastPlayText).kind == .underReview
        )
    }
}

public enum AlertKind: String, Sendable, Equatable {
    case scoring, turnover, redZone, fantasy
}

public struct AlertEvent: Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: AlertKind
    public var title: String
    /// May be empty: when the title and subtitle already say everything, a body would
    /// only repeat them.
    public var body: String
    public var subtitle: String?

    public init(id: String, kind: AlertKind, title: String, body: String, subtitle: String?) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.subtitle = subtitle
    }
}

public struct AlertSettings: Sendable {
    public var enabled: Bool
    public var favoritesOnly: Bool
    public var favorites: Set<String>
    public var scoring: Bool
    public var turnovers: Bool
    public var redZone: Bool

    public init(enabled: Bool = true, favoritesOnly: Bool = false,
                favorites: Set<String> = [], scoring: Bool = true,
                turnovers: Bool = true, redZone: Bool = true) {
        self.enabled = enabled
        self.favoritesOnly = favoritesOnly
        self.favorites = favorites
        self.scoring = scoring
        self.turnovers = turnovers
        self.redZone = redZone
    }
}

public enum AlertRules {

    /// A banner shows one line of title and one of subtitle, cut off with an ellipsis at
    /// roughly these lengths in the system font. Tests hold the text to them.
    public static let titleLimit = 45
    public static let subtitleLimit = 60

    /// What should fire for one game, given how it looked last time we looked.
    ///
    /// `previous == nil` means this is the first time the game has been seen, and
    /// nothing fires — otherwise every game in progress would alert at launch.
    public static func events(
        previous: GameSnapshot?,
        game: Game,
        settings: AlertSettings
    ) -> [AlertEvent] {
        guard settings.enabled, game.isLive, let previous else { return [] }
        guard !settings.favoritesOnly || isFavorite(game, settings.favorites) else { return [] }

        let play = PlaySummary.parse(game.situation?.lastPlayText)
        var events: [AlertEvent] = []

        let scoring = settings.scoring ? scoringEvent(previous: previous, game: game, play: play) : nil
        let turnover = settings.turnovers ? turnoverEvent(previous: previous, game: game, play: play) : nil
        if let scoring { events.append(scoring) }
        // A pick-six is one moment. The scoring banner already names who picked it off,
        // so a second "INT" banner for the same snap would only be noise. The same goes
        // when the score moved on an earlier poll than the text: the touchdown went out
        // then as a plain "TD DEN", and "TD DEN · pick-six" now would be a second banner
        // for one play. When the text arrives first, the scoring banner a poll later
        // carries the names.
        let scoreUnchanged = game.home.score == previous.homeScore
            && game.away.score == previous.awayScore
        let touchdownLeftToScoring = settings.scoring && play.touchdown != nil && scoreUnchanged
        if let turnover, scoring == nil || play.touchdown == nil, !touchdownLeftToScoring {
            events.append(turnover)
        }
        // The turnover banner already says where the new offense has the ball.
        if settings.redZone, turnover == nil,
           let event = redZoneEvent(previous: previous, game: game) {
            events.append(event)
        }
        return events
    }

    public static func isFavorite(_ game: Game, _ favorites: Set<String>) -> Bool {
        favorites.contains(game.home.abbreviation) || favorites.contains(game.away.abbreviation)
    }

    // MARK: - Scoring

    static func scoringEvent(previous: GameSnapshot, game: Game) -> AlertEvent? {
        scoringEvent(previous: previous, game: game,
                     play: PlaySummary.parse(game.situation?.lastPlayText))
    }

    /// Derived from the score changing rather than from `scoringPlays`, so it works for
    /// every game on the slate — the play feed is only fetched for one at a time. The
    /// scoreboard's `lastPlay` text supplies the names, but only when it describes a score
    /// of exactly the size that just landed; otherwise the banner stays generic.
    static func scoringEvent(previous: GameSnapshot, game: Game, play: PlaySummary) -> AlertEvent? {
        let homeDelta = game.home.score - previous.homeScore
        let awayDelta = game.away.score - previous.awayScore
        guard homeDelta > 0 || awayDelta > 0 else { return nil }

        var id = "score-\(game.id)-\(game.home.score)-\(game.away.score)"
        let subtitle = { (team: TeamSide?) in
            fitSubtitle([scoreLine(game, first: team), clockLine(game)])
        }

        // Both sides scoring between polls means polls were missed; one play's text
        // cannot explain both.
        if homeDelta > 0 && awayDelta > 0 {
            return AlertEvent(
                id: id, kind: .scoring,
                title: "\(game.away.abbreviation) +\(awayDelta) · \(game.home.abbreviation) +\(homeDelta)",
                body: "", subtitle: subtitle(nil)
            )
        }

        let team = homeDelta > 0 ? game.home : game.away
        let points = max(homeDelta, awayDelta)

        // The kick after a touchdown lands a poll or two after the touchdown itself
        // (observed live: +6 with the TD play, then +1 twelve seconds later). The
        // touchdown banner already went out; a lone "Extra point" banner is noise.
        guard points != 1 else { return nil }

        let playID = game.situation?.lastPlayID
        let textIsFresh = playID == nil || playID != previous.scoredPlayID
        // A return touchdown names the team that took the ball; if that is not the team
        // whose score moved, the text is about some other play.
        let textTeamAgrees = play.recoveringTeam
            .flatMap { Self.team(textAbbreviation: $0, in: game) }
            .map { $0.id == team.id } ?? true
        let trusted = textIsFresh && textTeamAgrees

        let label: String
        var details: [String] = []
        var body = ""
        switch points {
        // A range rather than `6, 7, 8`: a `where` clause only guards the last pattern.
        case 6...8 where trusted && play.touchdown != nil:
            label = "TD"
            details = touchdownDetails(play)
            body = touchdownBody(play)
            if play.takeaway != nil, let playID { id = "turnover-td-\(playID)" }
        case 6...8:
            label = "TD"
            if textIsFresh { body = tryNote(play.tryResult) ?? "" }
        case 3:
            label = "FG"
            if trusted, play.kind == .fieldGoal(.good) { details = kickDetails(play) }
        case 2 where trusted && play.kind == .safety:
            label = "Safety"
            details = play.scorer.map { [$0] } ?? []
        case 2 where play.tryResult == .defensiveTwoPoint:
            label = "Defensive 2-pt"
        case 2 where play.kind == .twoPointConversion(good: true) || play.tryResult == .twoPointGood:
            label = "2-pt good"
            if trusted, let scorer = play.scorer { details = [scorer] }
        default:
            // Two points with nothing saying safety or conversion, or a jump no single
            // score explains. Say only what is certain.
            return AlertEvent(id: id, kind: .scoring, title: "\(team.abbreviation) +\(points)",
                              body: "", subtitle: subtitle(team))
        }

        return AlertEvent(
            id: id,
            kind: .scoring,
            title: fit(details.map { "\(label) \(team.abbreviation) · \($0)" } + ["\(label) \(team.abbreviation)"]),
            body: body,
            subtitle: subtitle(team)
        )
    }

    /// Most to least detailed; the caller keeps the first that fits a title.
    static func touchdownDetails(_ play: PlaySummary) -> [String] {
        guard let touchdown = play.touchdown else { return [] }
        let how: String?
        switch touchdown {
        case .pass: how = "catch"
        case .rush: how = "run"
        case .interceptionReturn: how = "pick-six"
        case .fumbleReturn: how = "fumble return"
        case .puntReturn: how = "punt return"
        case .kickoffReturn: how = "kick return"
        case .blockedKickReturn:
            how = play.kind == .punt ? "blocked punt return"
                : play.kind == .fieldGoal(.blocked) ? "blocked FG return" : "blocked kick return"
        case .missedFieldGoalReturn: how = "missed FG return"
        case .fumbleRecovery: how = "fumble recovery"
        case .other: how = nil
        }
        guard let scorer = play.scorer else {
            // Still worth saying a defensive score was one, without a name.
            guard let how, touchdown != .pass, touchdown != .rush else { return [] }
            return [how.prefix(1).uppercased() + how.dropFirst()]
        }
        guard let how else { return [scorer] }
        let distance = (touchdown == .pass || touchdown == .rush) ? play.yards : (play.returnYards ?? play.yards)
        var options: [String] = []
        if let distance, distance > 0 { options.append("\(scorer) \(distance)-yd \(how)") }
        options.append("\(scorer) \(how)")
        options.append(scorer)
        return options
    }

    /// Only what the title could not hold: who threw it or who was robbed, and a try
    /// that did not go the routine way.
    static func touchdownBody(_ play: PlaySummary) -> String {
        var parts: [String] = []
        switch play.touchdown {
        case .pass?:
            if let passer = play.passer { parts.append("From \(passer)") }
        case .interceptionReturn?:
            if let passer = play.passer { parts.append("Picked off \(passer)") }
        case .fumbleReturn?:
            if let fumbler = play.fumbledBy {
                parts.append(play.kind == .sack ? "Strip-sack of \(fumbler)" : "\(fumbler) fumbled")
            }
        default:
            break
        }
        if let note = tryNote(play.tryResult) { parts.append(note) }
        return parts.joined(separator: " · ")
    }

    static func tryNote(_ result: PlaySummary.Try?) -> String? {
        switch result {
        case .extraPointMissed?: return "PAT no good"
        case .twoPointGood?: return "2-pt good"
        case .twoPointFailed?: return "2-pt failed"
        case .defensiveTwoPoint?: return "Defensive 2-pt return"
        case .extraPointGood?, nil: return nil
        }
    }

    static func kickDetails(_ play: PlaySummary) -> [String] {
        guard let kicker = play.kicker else { return [] }
        return play.yards.map { ["\(kicker) \($0) yd", kicker] } ?? [kicker]
    }

    // MARK: - Turnovers

    static func turnoverEvent(previous: GameSnapshot, game: Game) -> AlertEvent? {
        turnoverEvent(previous: previous, game: game,
                      play: PlaySummary.parse(game.situation?.lastPlayText))
    }

    /// Leads with who took the ball away and whose ball it is now. The play text is
    /// checked as well as ESPN's turnover flag: the scoreboard's flag comes from a short
    /// list of play types that misses strip-sacks, muffed punts and kick-return fumbles,
    /// and includes missed field goals, which are not turnovers at all.
    static func turnoverEvent(previous: GameSnapshot, game: Game, play: PlaySummary) -> AlertEvent? {
        guard let situation = game.situation, let playID = situation.lastPlayID,
              playID != previous.lastPlayID || previous.lastPlayUnderReview
        else { return nil }
        // Wait for the ruling instead of announcing a turnover replay may undo; the
        // snapshot remembers to look again. A flag that wiped the play out is nothing.
        guard play.kind != .underReview, play.kind != .noPlay else { return nil }

        let onDowns = play.takeaway == nil && isTurnoverOnDowns(previous: previous, game: game, play: play)
        guard play.takeaway != nil || situation.lastPlayWasTurnover || onDowns else { return nil }

        let ball = ballAfterTurnover(previous: previous, game: game, play: play)
        let ballPhrase = ball.map { ball in
            ball.spot.map { "\(ball.team.abbreviation) ball at \($0)" } ?? "\(ball.team.abbreviation) ball"
        }
        let subtitle = fitSubtitle([ballPhrase, scoreLine(game, first: ball?.team), clockLine(game)])
        let id = "turnover-\(playID)"

        if play.takeaway != nil, play.touchdown != nil {
            let deltas = (game.home.score - previous.homeScore, game.away.score - previous.awayScore)
            let scored = deltas.0 > 0 && deltas.1 <= 0 ? game.home : deltas.1 > 0 && deltas.0 <= 0 ? game.away : nil
            let team = ball?.team ?? scored
            let label = team.map { "TD \($0.abbreviation)" } ?? "TD"
            return AlertEvent(
                id: "turnover-td-\(playID)", kind: .turnover,
                title: fit(touchdownDetails(play).map { "\(label) · \($0)" } + [label]),
                body: touchdownBody(play),
                subtitle: fitSubtitle([scoreLine(game, first: team), clockLine(game)])
            )
        }

        let team = ball?.team.abbreviation
        let recovers = team.map { " · \($0) recovers" } ?? ""
        var titles: [String] = []
        var body: [String] = []

        switch play.takeaway {
        case .interception?:
            let label = team.map { "INT \($0)" } ?? "INT"
            if let picker = play.recoveredBy {
                if let passer = play.passer { titles.append("\(label) · \(picker) picks off \(passer)") }
                titles.append("\(label) · \(picker)")
            }
            titles.append(label)
            if let yards = play.returnYards, yards >= 10 { body.append("\(yards)-yd return") }

        case .fumble?:
            if let fumbler = play.fumbledBy {
                titles.append(team.map { "\(fumbler) fumbles · \($0) recovers" } ?? "Fumble lost · \(fumbler)")
            }
            titles.append(team.map { "Fumble · \($0) recovers" } ?? "Fumble lost")
            let forcer = play.forcedBy
            let sack = play.kind == .sack
            switch (forcer, play.recoveredBy) {
            case let (forcer?, recoverer?) where forcer == recoverer:
                body.append(sack ? "Strip-sack and recovery by \(forcer)" : "Forced and recovered by \(forcer)")
            case let (forcer, recoverer):
                if let forcer { body.append(sack ? "Strip-sack by \(forcer)" : "Forced by \(forcer)") }
                if let recoverer { body.append("recovered by \(recoverer)") }
            }

        case .muffedKick?:
            let kick = play.kind == .punt ? "punt" : "kick"
            if let muffer = play.fumbledBy { titles.append("\(muffer) muffs \(kick)\(recovers)") }
            titles.append("Muffed \(kick)\(recovers)")
            if let recoverer = play.recoveredBy { body.append("Recovered by \(recoverer)") }

        case .blockedKick?:
            let kick = play.kind == .punt ? "punt" : play.kind == .fieldGoal(.blocked) ? "FG" : "kick"
            titles.append("Blocked \(kick)\(recovers)")
            if let recoverer = play.recoveredBy { body.append("Recovered by \(recoverer)") }

        case nil where onDowns:
            titles.append(team.map { "Turnover on downs · \($0) ball" } ?? "Turnover on downs")
            let failed = shortDescription(play)
            body.append(joined([previous.shortDownDistance, failed]))

        case nil where play.kind == .fieldGoal(.missed):
            // Flagged by ESPN's play type, but a miss is not a turnover and saying so
            // would be wrong. Call it what it was.
            let kicking = game.team(id: previous.possessionTeamID)
                ?? ball.flatMap { ball in [game.home, game.away].first { $0.id != ball.team.id } }
            let label = kicking.map { "\($0.abbreviation) missed FG" } ?? "Missed FG"
            titles = kickDetails(play).map { "\(label) · \($0)" } + [label]
            if let detail = play.detail { body.append(String(detail.prefix(1)) + detail.dropFirst().lowercased()) }

        case nil:
            titles.append(team.map { "Turnover · \($0) ball" } ?? "Turnover")
        }

        let bodyText = body.joined(separator: " · ")
        return AlertEvent(
            id: onDowns ? "downs-\(playID)" : id,
            kind: .turnover,
            title: fit(titles),
            body: bodyText.prefix(1).uppercased() + bodyText.dropFirst(),
            subtitle: subtitle
        )
    }

    struct Ball: Equatable {
        var team: TeamSide
        /// "CIN 30" — only when the scoreboard itself has caught up.
        var spot: String?
    }

    /// Whose ball it is after a turnover.
    ///
    /// The scoreboard's possession is preferred once it has visibly changed since the last
    /// poll; before that it may still show the team that just lost the ball. A previous
    /// poll with no possession at all (ESPN drops it around kickoffs) counts as a change —
    /// live, possession has always updated in the same payload as the play. Fumbles name
    /// the recovering team in the text ("RECOVERED by SEA-J.Smith"), interceptions do not.
    /// If the two sources disagree, neither is used — wrong is worse than unsaid.
    static func ballAfterTurnover(previous: GameSnapshot, game: Game, play: PlaySummary) -> Ball? {
        var fromScoreboard: TeamSide?
        if let now = game.situation?.possessionTeamID, now != previous.possessionTeamID {
            fromScoreboard = game.team(id: now)
        }
        let fromText = play.recoveringTeam.flatMap { team(textAbbreviation: $0, in: game) }

        switch (fromScoreboard, fromText) {
        case let (scoreboard?, text?):
            return scoreboard.id == text.id ? Ball(team: scoreboard, spot: spot(game)) : nil
        case let (scoreboard?, nil):
            return Ball(team: scoreboard, spot: spot(game))
        case let (nil, text?):
            return Ball(team: text, spot: nil)
        case (nil, nil):
            return nil
        }
    }

    private static func spot(_ game: Game) -> String? {
        guard let text = game.situation?.possessionText, !text.isEmpty else { return nil }
        return text
    }

    /// Fourth down last poll, the other team's ball now, and the play in between was a
    /// snap rather than a punt or kick. There is no turnover-on-downs play type to key on.
    ///
    /// The clock check keeps a stale snapshot — the Mac asleep through a quarter — from
    /// reading an hour of football as one failed fourth down.
    static func isTurnoverOnDowns(previous: GameSnapshot, game: Game, play: PlaySummary) -> Bool {
        guard previous.down == 4,
              let before = previous.possessionTeamID,
              let now = game.situation?.possessionTeamID, now != before,
              game.home.score == previous.homeScore, game.away.score == previous.awayScore,
              previous.period == game.period,
              let then = seconds(previous.clock), let current = seconds(game.displayClock),
              then - current <= 60
        else { return false }
        switch play.kind {
        case .pass, .incompletePass, .rush, .sack: return true
        default: return false
        }
    }

    /// "M. Stafford incomplete to P. Nacua", "K. Williams 1-yd run", "K. Shakir catch, -1 yd".
    static func shortDescription(_ play: PlaySummary) -> String? {
        func gained(_ who: String, _ what: String) -> String {
            guard let yards = play.yards else { return "\(who) \(what)" }
            if yards > 0 { return "\(who) \(yards)-yd \(what)" }
            return yards == 0 ? "\(who) \(what), no gain" : "\(who) \(what), \(yards) yd"
        }
        switch play.kind {
        case .incompletePass:
            guard let passer = play.passer else { return nil }
            return "\(passer) incomplete" + (play.receiver.map { " to \($0)" } ?? "")
        case .pass:
            return play.receiver.map { gained($0, "catch") }
        case .rush:
            return play.rusher.map { gained($0, "run") }
        case .sack:
            return play.passer.map { "\($0) sacked" }
        default:
            return nil
        }
    }

    // MARK: - Red zone

    /// Fires once on entering the red zone, not on every snap inside the 20 — so it is
    /// suppressed while the same team stays there, and re-arms on a change of possession.
    ///
    /// ESPN reports the ball as inside the 20 with *no* possession while a try or field
    /// goal is being lined up, and after timeouts that follow one. Keying on possession
    /// and an unchanged score keeps every long touchdown from also announcing a red zone
    /// trip that already ended in points.
    static func redZoneEvent(previous: GameSnapshot, game: Game) -> AlertEvent? {
        guard let situation = game.situation, situation.isRedZone,
              let team = game.teamWithPossession,
              game.home.score == previous.homeScore, game.away.score == previous.awayScore
        else { return nil }
        let possessionChanged = previous.possessionTeamID.map { $0 != team.id } ?? false
        guard !previous.isRedZone || possessionChanged else { return nil }

        return AlertEvent(
            id: "redzone-\(game.id)-\(team.id)-\(game.home.score)-\(game.away.score)",
            kind: .redZone,
            title: "\(team.abbreviation) in the red zone",
            body: "",
            subtitle: fitSubtitle([situation.downDistanceText, scoreLine(game, first: team), clockLine(game)])
        )
    }

    // MARK: - Text

    /// "CIN 14–10 BAL": the leader first, as a headline would put it. Level scores put
    /// the team the alert is about first.
    static func scoreLine(_ game: Game, first preferred: TeamSide? = nil) -> String {
        let (a, b): (TeamSide, TeamSide)
        if game.home.score != game.away.score {
            (a, b) = game.home.score > game.away.score ? (game.home, game.away) : (game.away, game.home)
        } else {
            (a, b) = preferred?.id == game.home.id ? (game.home, game.away) : (game.away, game.home)
        }
        return "\(a.abbreviation) \(a.score)–\(b.score) \(b.abbreviation)"
    }

    /// "Q2 5:12", "HALF", "OT 3:40".
    static func clockLine(_ game: Game) -> String? {
        let period = game.periodLabel
        guard !period.isEmpty else { return nil }
        if game.phase == .halftime || game.displayClock.isEmpty { return period }
        return "\(period) \(game.displayClock)"
    }

    /// Team as named in play text, which abbreviates some teams its own way.
    static func team(textAbbreviation: String, in game: Game) -> TeamSide? {
        let mapped = PlaySummary.scoreboardAbbreviation(textAbbreviation)
        return [game.home, game.away].first {
            $0.abbreviation == mapped || $0.abbreviation == textAbbreviation
        }
    }

    /// The first candidate that fits a title, else the shortest.
    static func fit(_ candidates: [String], limit: Int = titleLimit) -> String {
        candidates.first { $0.count <= limit } ?? candidates.min { $0.count < $1.count } ?? ""
    }

    /// Joins facts in priority order, dropping from the least important end until the
    /// line fits — the clock goes before the score, the score before whose ball it is.
    static func fitSubtitle(_ parts: [String?], limit: Int = subtitleLimit) -> String {
        var kept = parts.compactMap { $0 }.filter { !$0.isEmpty }
        var line = kept.joined(separator: " · ")
        while line.count > limit, kept.count > 1 {
            kept.removeLast()
            line = kept.joined(separator: " · ")
        }
        return line
    }

    static func joined(_ parts: [String?]) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// "5:12" → 312.
    static func seconds(_ clock: String?) -> Int? {
        guard let clock else { return nil }
        let pieces = clock.split(separator: ":").compactMap { Int($0) }
        guard pieces.count == 2 else { return nil }
        return pieces[0] * 60 + pieces[1]
    }
}
