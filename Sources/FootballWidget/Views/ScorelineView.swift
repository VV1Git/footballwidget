import SwiftUI
import FootballCore

/// One team's logo, abbreviation and score. Shared by the game detail header and the
/// RedZone spotlight, so the two read the same way.
struct TeamScore: View {
    let team: TeamSide
    /// The corner-window size: smaller logo and score, no record.
    var compact = false

    var body: some View {
        let logo: CGFloat = compact ? 16 : 24
        HStack(spacing: compact ? 4 : 7) {
            TeamLogo(url: team.logoURL, fallbackTint: team.tint)
                .frame(width: logo, height: logo)
            VStack(alignment: .leading, spacing: 0) {
                Text(team.abbreviation)
                    .font(.system(size: compact ? 10 : 11, weight: .semibold))
                if !compact, let record = team.record {
                    Text(record)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            Text("\(team.score)")
                .font(.system(size: compact ? 17 : 24, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
    }
}

enum GameStatusText {
    /// Everything worth knowing on one short line: "Q3 2:14 · KC ball · 3rd & 4".
    static func compact(_ game: Game) -> String {
        var parts: [String] = []
        switch game.phase {
        case .pre:
            parts.append(game.statusDetail)
        case .final:
            parts.append(game.period > 4 ? "Final/OT" : "Final")
        case .halftime:
            parts.append("Half")
        default:
            let clock = game.displayClock.isEmpty ? "" : " \(game.displayClock)"
            parts.append("\(game.periodLabel)\(clock)")
        }
        if let team = game.teamWithPossession { parts.append("\(team.abbreviation) ball") }
        if let down = game.situation?.shortDownDistance, !down.isEmpty { parts.append(down) }
        return parts.joined(separator: " · ")
    }
}
