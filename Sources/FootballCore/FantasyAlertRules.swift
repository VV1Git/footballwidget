import Foundation

/// One rostered player's scoring moving, with whatever the play feed could tell us
/// about why.
public struct FantasyMoment: Sendable, Hashable {
    public var player: RosterPlayer
    public var isMine: Bool
    /// Points gained since the last poll. Already rounded to two places.
    public var delta: Double
    /// The play credited with the change, if one could be identified.
    public var playText: String?
    public var isTouchdown: Bool

    public init(player: RosterPlayer, isMine: Bool, delta: Double,
                playText: String?, isTouchdown: Bool) {
        self.player = player
        self.isMine = isMine
        self.delta = delta
        self.playText = playText
        self.isTouchdown = isTouchdown
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

    /// `leagueName` is included in the banner when more than one league is connected,
    /// so "Yours · Ja'Marr Chase +12.4" says which team of yours it was for.
    public static func events(
        moments: [FantasyMoment],
        matchup: FantasyMatchup,
        settings: FantasyAlertSettings,
        leagueName: String? = nil
    ) -> [AlertEvent] {
        guard settings.enabled else { return [] }
        return moments.compactMap {
            event(for: $0, matchup: matchup, settings: settings, leagueName: leagueName)
        }
    }

    static func event(
        for moment: FantasyMoment,
        matchup: FantasyMatchup,
        settings: FantasyAlertSettings,
        leagueName: String? = nil
    ) -> AlertEvent? {
        guard qualifies(moment, settings: settings) else { return nil }

        let side = moment.isMine ? "Yours" : "Opp"
        let points = formatted(moment.delta, signed: true)
        let total = formatted(moment.player.points, signed: false)

        var facts = [moment.isTouchdown ? "TD" : moment.player.position.rawValue]
        facts.append("\(total) total")
        facts.append(matchupLine(matchup))
        if let leagueName, !leagueName.isEmpty { facts.append(leagueName) }

        return AlertEvent(
            // Keyed to the player's running total so the same play cannot fire twice,
            // while a genuine second score for the same player still can. The league is
            // part of the key so the same player scoring in two leagues alerts for both.
            id: "fantasy-\(leagueName ?? "")-\(moment.player.id)-\(total)",
            kind: .fantasy,
            title: "\(side) · \(moment.player.fullName) \(points)",
            body: playLine(for: moment) ?? "\(moment.player.fullName) scored \(points)",
            subtitle: facts.joined(separator: " · ")
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
        // Stat corrections move totals down hours later; never interrupt for those.
        guard moment.delta > 0 else { return false }
        if settings.startersOnly && !moment.player.isStarter { return false }
        return moment.isTouchdown || moment.delta >= settings.threshold
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
