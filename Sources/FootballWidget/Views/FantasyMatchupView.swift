import SwiftUI
import FootballCore

/// Your fantasy matchup: your starters against your opponent's, live.
struct FantasyMatchupView: View {
    var onBack: (() -> Void)?

    @Environment(FantasyStore.self) private var fantasy
    @Environment(GameStore.self) private var games
    @Environment(\.openSettings) private var openSettings
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)

            if let matchup = fantasy.matchup {
                ScrollView {
                    FantasyMatchupContent(matchup: matchup, winProbability: fantasy.winProbability)
                        .padding(Metrics.gutter)
                }
                .scrollIndicators(.never)
            } else {
                statusPanel
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.glass)
                .help("Back to all games")
            }
            Spacer()
            VStack(spacing: 1) {
                if fantasy.leagueIDs.count > 1 {
                    leaguePicker
                } else {
                    Text(fantasy.matchup?.leagueName ?? "Fantasy")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                }
                if let week = fantasy.matchup?.week {
                    Text("Week \(week)")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Color.clear.frame(width: 24, height: 1)
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, 10)
    }

    /// Only shown once a second league is connected, so a single-league setup keeps a
    /// plain title rather than a menu with one item in it.
    private var leaguePicker: some View {
        Menu {
            ForEach(fantasy.leagueIDs, id: \.self) { leagueID in
                Button {
                    fantasy.selectLeague(leagueID)
                } label: {
                    let name = fantasy.matchup(for: leagueID)?.leagueName ?? "League \(leagueID)"
                    if leagueID == fantasy.activeLeagueID {
                        Label(name, systemImage: "checkmark")
                    } else {
                        Text(name)
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(fantasy.matchup?.leagueName ?? "Fantasy")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: - Not connected

    private var statusPanel: some View {
        VStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text(statusText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
            Button("Open Fantasy settings") {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            }
            .buttonStyle(.glass)
            .font(.system(size: 10))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 40)
    }

    private var iconName: String {
        switch fantasy.state {
        case .connecting: return "arrow.trianglehead.2.clockwise"
        case .failed: return "exclamationmark.triangle"
        default: return "person.2"
        }
    }

    private var statusText: String {
        switch fantasy.state {
        case .notConfigured: return "Connect your ESPN fantasy league to see your matchup here."
        case .connecting: return "Connecting…"
        case .connected: return "No matchup this week."
        case .failed(let message): return message
        }
    }
}

/// The body of the matchup, split out from the scrolling container so it can also be
/// rendered offscreen — `ImageRenderer` does not lay out `ScrollView` content.
struct FantasyMatchupContent: View {
    let matchup: FantasyMatchup
    /// Computed by the store when data arrives, never here.
    var winProbability: WinProbability? = nil

    @Environment(GameStore.self) private var games

    var body: some View {
        VStack(spacing: 10) {
            scoreboard(matchup)
            lineup(matchup)
        }
    }

    // MARK: - Score

    fileprivate func scoreboard(_ matchup: FantasyMatchup) -> some View {
        VStack(spacing: 9) {
            totals(matchup)
            if let winProbability, matchup.opponent != nil {
                WinProbabilityBar(probability: winProbability)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassCard()
    }

    fileprivate func totals(_ matchup: FantasyMatchup) -> some View {
        HStack(alignment: .center, spacing: 10) {
            teamTotal(matchup.mine, label: "You", leading: matchup.margin > 0)
            VStack(spacing: 1) {
                Text(marginText(matchup))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(matchup.margin >= 0 ? .green : .red)
                    .monospacedDigit()
            }
            .frame(width: 54)
            if let opponent = matchup.opponent {
                teamTotal(opponent, label: opponent.abbreviation, leading: matchup.margin < 0)
            } else {
                Text("Bye")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    fileprivate func marginText(_ matchup: FantasyMatchup) -> String {
        guard matchup.opponent != nil else { return "—" }
        let value = abs(matchup.margin)
        let sign = matchup.margin >= 0 ? "+" : "−"
        return "\(sign)\(String(format: "%.1f", value))"
    }

    fileprivate func teamTotal(_ team: FantasyTeam, label: String, leading: Bool) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(String(format: "%.1f", team.points))
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(leading ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Lineup

    fileprivate func lineup(_ matchup: FantasyMatchup) -> some View {
        let mine = matchup.mine.starters
        let theirs = matchup.opponent?.starters ?? []
        // Both lineups are in slot order, so the columns mostly pair up by position.
        // Rows run to the longer of the two — zipping would silently drop players from
        // whichever side has more starters.
        let rowCount = max(mine.count, theirs.count)

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Starters")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("live points")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            ForEach(0..<rowCount, id: \.self) { index in
                HStack(spacing: 6) {
                    playerCell(index < mine.count ? mine[index] : nil, alignment: .leading)
                    playerCell(index < theirs.count ? theirs[index] : nil, alignment: .trailing)
                }
            }
        }
    }

    @ViewBuilder
    fileprivate func playerCell(_ player: RosterPlayer?, alignment: HorizontalAlignment) -> some View {
        if let player {
            HStack(spacing: 5) {
                if alignment == .trailing {
                    Text(String(format: "%.1f", player.points))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                VStack(alignment: alignment == .leading ? .leading : .trailing, spacing: 0) {
                    Text(player.fullName)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(spacing: 3) {
                        Text(player.slot.label)
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        if isPlaying(player) {
                            LivePulse()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
                if alignment == .leading {
                    Text(String(format: "%.1f", player.points))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.primary.opacity(0.04))
            )
        } else {
            Color.clear.frame(maxWidth: .infinity, minHeight: 26)
        }
    }

    fileprivate func isPlaying(_ player: RosterPlayer) -> Bool {
        guard let proTeamID = player.proTeamID else { return false }
        let team = String(proTeamID)
        return games.games.contains { $0.isLive && ($0.home.id == team || $0.away.id == team) }
    }

}

/// Chance to win laid out the way ESPN's FantasyCast does it: one bar split between the
/// two sides, each end labelled with its percentage. Green is yours and orange theirs,
/// the same pairing as the chips on the play map. Pure layout; the numbers arrive done.
struct WinProbabilityBar: View {
    let probability: WinProbability

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                percent(probability.myPercentText, favoured: probability.myPercent >= 50)
                Spacer(minLength: 4)
                Text(caption)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                percent(probability.theirPercentText, favoured: probability.theirPercent >= 50)
            }

            bar

            if !probability.isSettled,
               let mine = probability.projectedMine,
               let theirs = probability.projectedTheirs {
                HStack {
                    Text("Proj \(String(format: "%.1f", mine))")
                    Spacer()
                    Text("Proj \(String(format: "%.1f", theirs))")
                }
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            }
        }
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Chance to win: you \(probability.myPercentText), opponent \(probability.theirPercentText)")
    }

    private func percent(_ text: String, favoured: Bool) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(favoured ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
    }

    private var bar: some View {
        // While games remain, neither side is drawn as nothing: the bar should not look
        // more certain than the ">99%" printed above it.
        let share = probability.isSettled
            ? probability.mine
            : min(max(probability.mine, 0.01), 0.99)
        let gap: CGFloat = share > 0 && share < 1 ? 2 : 0

        return GeometryReader { proxy in
            let usable = max(proxy.size.width - gap, 0)
            HStack(spacing: gap) {
                if share > 0 {
                    Capsule().fill(Color.green).frame(width: usable * share)
                }
                if share < 1 {
                    Capsule().fill(Color.orange)
                }
            }
        }
        .frame(height: 5)
    }

    private var caption: String {
        switch probability.source {
        case .espn: return "Chance to win"
        case .model: return "Chance to win (est.)"
        case .result: return "Final"
        }
    }

    private var helpText: String {
        switch probability.source {
        case .espn:
            return "ESPN's win probability for this matchup."
        case .model:
            return "ESPN did not send a win probability, so this one is estimated from its player projections and how much of each game is left."
        case .result:
            return "Every starter's game is over."
        }
    }
}
