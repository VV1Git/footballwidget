import Foundation

/// One play scoring for a rostered player.
public struct FantasyMoment: Sendable, Hashable {
    /// His `points` are his total for the game so far, this play included.
    public var player: RosterPlayer
    public var isMine: Bool
    /// What the play changed his score by. Already rounded to two places.
    public var delta: Double
    /// The play that scored.
    public var playText: String?
    public var isTouchdown: Bool
    /// The play the points belong to. A player alerts at most once per play.
    public var playID: String?
    /// Everything the play is worth to him. Scored from the play itself, so it is the
    /// same figure as `delta`; kept apart so a caller with a running figure for the play
    /// can judge it on that. Without a play it is just `delta`.
    public var pointsOnPlay: Double
    /// Points that belong to a play long gone — a correction, or a play from before
    /// anyone was watching. Never worth an interruption.
    public var isCorrection: Bool

    public init(player: RosterPlayer, isMine: Bool, delta: Double,
                playText: String?, isTouchdown: Bool,
                playID: String? = nil, pointsOnPlay: Double? = nil,
                isCorrection: Bool = false) {
        self.player = player
        self.isMine = isMine
        self.delta = delta
        self.playText = playText
        self.isTouchdown = isTouchdown
        self.playID = playID
        self.pointsOnPlay = pointsOnPlay ?? delta
        self.isCorrection = isCorrection
    }
}

public struct FantasyAlertSettings: Sendable {
    public var enabled: Bool
    /// Points a single play must be worth to interrupt you, when it is not a touchdown.
    public var threshold: Double
    /// Bench players cannot score for you, so by default they stay quiet.
    public var startersOnly: Bool

    public init(enabled: Bool = true, threshold: Double = 6.0, startersOnly: Bool = true) {
        self.enabled = enabled
        self.threshold = threshold
        self.startersOnly = startersOnly
    }
}

public enum FantasyAlertRules {

    /// The least a touchdown play can be worth to the player who scored or threw it,
    /// in any common scoring: four for a passing touchdown, six for the rest. A
    /// touchdown worth less than that in his league — none for throwing one, say — is
    /// held to the threshold like any other play.
    public static let touchdownFloor = 4.0

    /// `leagueName` is included in the banner when more than one league is connected,
    /// so "Yours · Ja'Marr Chase +12.4" says which team of yours it was for.
    /// `leagueID` keys the alert, so it stays the same if the league is renamed.
    public static func events(
        moments: [FantasyMoment],
        matchup: FantasyMatchup,
        settings: FantasyAlertSettings,
        leagueName: String? = nil,
        leagueID: String? = nil
    ) -> [AlertEvent] {
        guard settings.enabled else { return [] }
        return moments.compactMap {
            event(for: $0, matchup: matchup, settings: settings,
                  leagueName: leagueName, leagueID: leagueID)
        }
    }

    static func event(
        for moment: FantasyMoment,
        matchup: FantasyMatchup,
        settings: FantasyAlertSettings,
        leagueName: String? = nil,
        leagueID: String? = nil
    ) -> AlertEvent? {
        guard qualifies(moment, settings: settings) else { return nil }

        let side = moment.isMine ? "Yours" : "Opp"
        let points = formatted(moment.pointsOnPlay, signed: true)
        let total = formatted(moment.player.points, signed: false)

        // Least important last, as that is the end a long line loses first: a long
        // league name, then the matchup score, so the banner never runs past its line.
        let facts = [
            moment.isTouchdown ? "TD" : moment.player.position.rawValue,
            "\(total) total",
            matchupLine(matchup),
            leagueName,
        ]

        // Keyed to the play, so however often it is scored again — its text corrected,
        // the feed fetched once more — it alerts once. Keying it to the player's running
        // total, as it used to be, made every new total a new alert. With no play to key
        // on the total is all there is. The league is part of the key so the same player
        // scoring in two leagues alerts for both.
        let league = leagueID ?? leagueName ?? ""
        let id = moment.playID.map { "fantasy-\(league)-\(moment.player.id)-play-\($0)" }
            ?? "fantasy-\(league)-\(moment.player.id)-\(total)"

        return AlertEvent(
            id: id,
            kind: .fantasy,
            title: "\(side) · \(moment.player.fullName) \(points)",
            body: playLine(for: moment) ?? "\(moment.player.fullName) scored \(points)",
            subtitle: AlertRules.fitSubtitle(facts)
        )
    }

    /// What the player did, from his side of the play: "14-yd catch from J. Burrow"
    /// rather than the whole gamebook sentence. The subtitle already says "TD", so the
    /// line does not repeat it.
    ///
    /// When the play cannot be read from his point of view — a defense, or phrasing the
    /// parser does not know — the play text is cleaned of formation and snapper credits
    /// and shortened instead.
    static func playLine(for moment: FantasyMoment) -> String? {
        guard let text = moment.playText, !text.isEmpty else { return nil }
        let play = PlaySummary.parse(text)
        let player = moment.player
        func isHim(_ name: String?) -> Bool {
            PlaySummary.name(name, matchesFirst: player.firstName, last: player.lastName)
        }
        func gain(_ yards: Int?) -> String { yards.map { $0 > 0 ? "\($0)-yd " : "" } ?? "" }
        let isPass = play.kind == .pass || play.touchdown == .pass

        if isPass, isHim(play.receiver) {
            return "\(gain(play.yards))catch" + (play.passer.map { " from \($0)" } ?? "")
        }
        if isPass, isHim(play.passer) {
            return "\(gain(play.yards))pass" + (play.receiver.map { " to \($0)" } ?? "")
        }
        if play.kind == .rush, isHim(play.rusher) {
            return "\(gain(play.yards))run"
        }
        if play.kind == .fieldGoal(.good), isHim(play.kicker) {
            return "\(gain(play.yards))field goal"
        }
        if play.touchdown != nil, isHim(play.scorer),
           let how = AlertRules.touchdownDetails(play).first(where: { $0.hasPrefix(play.scorer ?? "") }) {
            // "D. Knight 27-yd fumble return" → "27-yd fumble return"
            return String(how.dropFirst((play.scorer ?? "").count)).trimmingCharacters(in: .whitespaces)
        }
        return trimmed(condensed(text))
    }

    /// Drops what a banner has no room for: `(Shotgun)`, `(9:44)`, "reported in as
    /// eligible", and the long snapper and holder on kicks.
    static func condensed(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "\n", with: " ")
        let clutter = [
            "^\\s*(?:\\([^)]*\\)\\s*)+",
            "[A-Z][a-z]{0,2}\\.[A-Za-z'\\- ]+? reported in as eligible\\.\\s*",
            ",?\\s*(?:Center|Holder)-[A-Z][a-z]{0,2}\\.[A-Za-z'\\-]+",
            "\\s{2,}",
        ]
        for pattern in clutter {
            result = result.replacingOccurrences(of: pattern, with: pattern == "\\s{2,}" ? " " : "",
                                                 options: .regularExpression)
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    static func qualifies(_ moment: FantasyMoment, settings: FantasyAlertSettings) -> Bool {
        // A play that cost points, or one long gone, is never worth an interruption.
        guard moment.delta > 0, !moment.isCorrection else { return false }
        if settings.startersOnly && !moment.player.isStarter { return false }
        // A touchdown alerts whatever the threshold — as long as it is worth a
        // touchdown's points to him, which a kicker's extra point on the same play is not.
        if moment.isTouchdown && moment.pointsOnPlay >= touchdownFloor { return true }
        return moment.pointsOnPlay >= settings.threshold
    }

    // MARK: - Text

    static func matchupLine(_ matchup: FantasyMatchup) -> String {
        guard matchup.opponent != nil else {
            return "You \(formatted(matchup.mine.points, signed: false))"
        }
        return "You \(matchup.compactScore)"
    }

    static func formatted(_ value: Double, signed: Bool) -> String {
        let rounded = (value * 10).rounded() / 10
        let text = String(format: "%.1f", abs(rounded))
        if !signed { return text }
        return rounded < 0 ? "-\(text)" : "+\(text)"
    }

    /// Play descriptions run long; a notification body shows roughly two lines, and one
    /// is plenty once the headline facts are in the title and subtitle.
    static func trimmed(_ text: String?, limit: Int = 72) -> String? {
        guard let text, !text.isEmpty else { return nil }
        guard text.count > limit else { return text }
        let cut = text.prefix(limit)
        // Break on a word so it does not end mid-name.
        if let space = cut.lastIndex(of: " ") {
            return String(cut[..<space]) + "…"
        }
        return String(cut) + "…"
    }
}
