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
            body: trimmed(moment.playText) ?? "\(moment.player.fullName) scored \(points)",
            subtitle: facts.joined(separator: " · ")
        )
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

    /// Play descriptions run long; a notification body shows roughly two lines.
    static func trimmed(_ text: String?, limit: Int = 96) -> String? {
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
