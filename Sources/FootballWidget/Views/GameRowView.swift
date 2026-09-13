import SwiftUI
import FootballCore

/// One game in the panel list: both teams, the score, and — while live — who has the
/// ball, where it is and how long is left.
struct GameRowView: View {
    let game: Game
    let onSelect: () -> Void
    /// Called with the abbreviation of the specific team that was starred.
    let onToggleFavorite: (String) -> Void

    @Environment(Preferences.self) private var preferences
    @Environment(FantasyStore.self) private var fantasy

    @Environment(\.colorScheme) private var scheme
    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .center, spacing: 10) {
                VStack(spacing: 4) {
                    teamLine(game.away)
                    teamLine(game.home)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 3) {
                    statusColumn
                    fantasyBadge
                }
                .frame(width: 96, alignment: .trailing)

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(isHovering ? 1 : 0.35)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassCard(tint: cardTint, interactive: true)
        .onHover { isHovering = $0 }
    }

    // MARK: - Teams

    private func teamLine(_ team: TeamSide) -> some View {
        HStack(spacing: 6) {
            favoriteStar(team)

            TeamLogo(url: team.logoURL, fallbackTint: team.tint)
                .frame(width: 17, height: 17)

            Text(team.abbreviation)
                .font(.system(size: 12, weight: isLosing(team) ? .regular : .semibold))
                .foregroundStyle(isLosing(team) ? .secondary : .primary)

            if hasPossession(team) {
                Image(systemName: "football.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(team.tint.legibleOnGlass(dark: scheme == .dark))
                    .transition(.scale.combined(with: .opacity))
            }

            if game.phase == .pre, let record = team.record {
                Text(record)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 4)

            if game.phase != .pre {
                Text("\(team.score)")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isLosing(team) ? .secondary : .primary)
            }
        }
    }

    private func hasPossession(_ team: TeamSide) -> Bool {
        game.isLive && game.situation?.possessionTeamID == team.id
    }

    /// Dim the trailing team so the scoreline reads at a glance.
    private func isLosing(_ team: TeamSide) -> Bool {
        guard game.phase != .pre else { return false }
        let other = team.id == game.home.id ? game.away : game.home
        return team.score < other.score
    }

    // MARK: - Status

    @ViewBuilder
    private var statusColumn: some View {
        VStack(alignment: .trailing, spacing: 2) {
            switch game.phase {
            case .pre:
                Text(kickoffText)
                    .font(.system(size: 11, weight: isToday ? .semibold : .medium))
                    .foregroundStyle(isToday ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                if let broadcast = game.broadcast {
                    Text(broadcast)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }

            case .final:
                Text(game.period > 4 ? "Final/OT" : "Final")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

            case .halftime:
                Text("Halftime")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

            case .live, .unknown:
                HStack(spacing: 4) {
                    LivePulse()
                    Text("\(game.periodLabel) \(game.displayClock)")
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                }
                if let situation = game.situation {
                    Text(situation.shortDownDistance ?? situation.downDistanceText ?? "")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let spot = situation.possessionText, !spot.isEmpty {
                        Text(spot)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(situation.isRedZone ? AnyShapeStyle(Color.red) : AnyShapeStyle(.tertiary))
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private var kickoffText: String {
        guard let kickoff = game.kickoff else { return game.statusDetail }
        let formatter = DateFormatter()
        let calendar = Calendar.current
        if calendar.isDateInToday(kickoff) {
            formatter.dateFormat = "h:mm a"
            // Spelling out "Today" beats leaving it implicit in a list that spans the
            // whole week — a bare time reads like just another Sunday game.
            return "Today \(formatter.string(from: kickoff))"
        }
        if calendar.isDateInTomorrow(kickoff) {
            formatter.dateFormat = "h:mm a"
            return "Tomorrow \(formatter.string(from: kickoff))"
        }
        formatter.dateFormat = "E h:mm a"
        return formatter.string(from: kickoff)
    }

    private var isToday: Bool {
        guard let kickoff = game.kickoff else { return false }
        return Calendar.current.isDateInToday(kickoff)
    }

    /// How many of your starters are playing in this game.
    @ViewBuilder
    private var fantasyBadge: some View {
        let count = fantasy.myPlayerCount(inGame: game)
        if count > 0 {
            HStack(spacing: 2) {
                Image(systemName: "person.fill")
                    .font(.system(size: 6))
                Text("\(count)")
                    .font(.system(size: 8, weight: .bold))
                    .monospacedDigit()
            }
            .foregroundStyle(Color.green)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.green.opacity(0.15)))
            .help("\(count) of your starters \(count == 1 ? "is" : "are") in this game")
        }
    }

    // MARK: - Chrome

    private var cardTint: Color? {
        guard game.isLive else { return nil }
        if game.situation?.isRedZone == true { return .red }
        return game.teamWithPossession?.tint
    }

    /// Sits in a fixed-width slot so showing it on hover never shifts the row.
    private func favoriteStar(_ team: TeamSide) -> some View {
        let isOn = preferences.isFavorite(team.abbreviation)
        return Button {
            onToggleFavorite(team.abbreviation)
        } label: {
            Image(systemName: isOn ? "star.fill" : "star")
                .font(.system(size: 8))
                .foregroundStyle(isOn ? AnyShapeStyle(Color.yellow) : AnyShapeStyle(.tertiary))
        }
        .buttonStyle(.plain)
        .frame(width: 9)
        .opacity(isOn ? 1 : (isHovering ? 0.7 : 0))
        .help(isOn ? "Unfavorite \(team.displayName)" : "Favorite \(team.displayName)")
    }
}

/// A quiet breathing dot, so "live" reads without shouting.
struct LivePulse: View {
    @State private var on = false

    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: 5, height: 5)
            .opacity(on ? 1 : 0.35)
            .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

/// Team logo with a coloured dot as a stand-in while it loads or if it fails.
struct TeamLogo: View {
    let url: URL?
    let fallbackTint: Color

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: .fit)
            default:
                Circle().fill(fallbackTint.opacity(0.55))
            }
        }
    }
}
