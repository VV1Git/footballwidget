import SwiftUI
import FootballCore

/// One game on its own: the scoreline, the field map for a chosen drive, and the
/// drive log underneath.
struct GameDetailView: View {
    let game: Game
    let detail: GameDetail?
    /// Nil in the torn-off window, which has nowhere to go back to.
    var onBack: (() -> Void)?
    var onPin: (() -> Void)?

    @Environment(FantasyStore.self) private var fantasy
    @Environment(Preferences.self) private var preferences
    @State private var selectedDriveID: String?
    @State private var expandedPlayID: String?
    @Environment(\.colorScheme) private var scheme

    /// How much room there is. A torn-off window can be shrunk to a sliver, so the
    /// view sheds whole sections rather than letting everything squash.
    private enum Density {
        /// Scoreline only — enough to keep an eye on a game in a corner.
        case tiny
        /// Scoreline and the field map.
        case compact
        /// Everything, including the drive log.
        case regular

        static func of(_ size: CGSize) -> Density {
            if size.height < 190 || size.width < 230 { return .tiny }
            if size.height < 330 || size.width < 320 { return .compact }
            return .regular
        }
    }

    private var drives: [Drive] { detail?.drives ?? [] }

    /// Whatever the user picked, else the newest drive.
    private var activeDrive: Drive? {
        if let selectedDriveID, let match = drives.first(where: { $0.id == selectedDriveID }) {
            return match
        }
        return drives.first
    }

    private var offense: TeamSide? { game.team(id: activeDrive?.teamID) }
    private var defense: TeamSide? {
        guard let offense else { return nil }
        return offense.id == game.home.id ? game.away : game.home
    }

    var body: some View {
        GeometryReader { proxy in
            let density = Density.of(proxy.size)

            VStack(spacing: 0) {
                header(density)
                if density != .tiny {
                    Divider().opacity(0.5)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            fieldSection(width: proxy.size.width, density: density)
                            // Shown whenever there is any room at all. Gating these on
                            // the widest layout left a short drive floating above a
                            // block of empty window.
                            fantasySection
                            driveLogSection
                        }
                        .padding(density == .compact ? 8 : Metrics.gutter)
                    }
                    .scrollIndicators(.never)
                }
            }
        }
        .onChange(of: detail?.drives.first?.id) { _, _ in
            // A new drive started: collapse any play the user had opened on the old one.
            if selectedDriveID == nil { expandedPlayID = nil }
        }
    }

    // MARK: - Header

    private func header(_ density: Density) -> some View {
        VStack(spacing: density == .tiny ? 4 : 8) {
            if density != .tiny || onBack != nil {
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

                statusPill

                Spacer()

                if let onPin {
                    Button(action: onPin) {
                        Image(systemName: "pin")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.glass)
                    .help("Keep this game in its own window")
                } else {
                    Color.clear.frame(width: 24, height: 1)
                }
            }
            }

            HStack(alignment: .center, spacing: density == .tiny ? 6 : 12) {
                scoreBlock(game.away, density)
                Text("–")
                    .font(.system(size: 15, weight: .light))
                    .foregroundStyle(.tertiary)
                scoreBlock(game.home, density)
            }

            if density == .tiny {
                // The clock is the reason to keep a small window open, so it survives
                // even when the toolbar row above does not.
                HStack(spacing: 4) {
                    if game.isLive { LivePulse() }
                    Text(compactStatus)
                        .font(.system(size: 9, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else if game.isLive, let situation = game.situation {
                HStack(spacing: 6) {
                    if let team = game.teamWithPossession {
                        Image(systemName: "football.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(team.tint.legibleOnGlass(dark: scheme == .dark))
                        Text(team.abbreviation)
                            .font(.system(size: 10, weight: .semibold))
                    }
                    if let text = situation.downDistanceText, !text.isEmpty {
                        Text(text)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    if situation.isRedZone {
                        Text("RED ZONE")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.red.opacity(0.14), in: Capsule())
                    }
                }
            }
        }
        .padding(.horizontal, density == .tiny ? 8 : Metrics.gutter)
        .padding(.vertical, density == .tiny ? 6 : 10)
    }

    private func scoreBlock(_ team: TeamSide, _ density: Density) -> some View {
        let logo: CGFloat = density == .tiny ? 16 : 24
        return HStack(spacing: density == .tiny ? 4 : 7) {
            TeamLogo(url: team.logoURL, fallbackTint: team.tint)
                .frame(width: logo, height: logo)
            VStack(alignment: .leading, spacing: 0) {
                Text(team.abbreviation)
                    .font(.system(size: density == .tiny ? 10 : 11, weight: .semibold))
                if density != .tiny, let record = team.record {
                    Text(record)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            Text("\(team.score)")
                .font(.system(size: density == .tiny ? 17 : 24, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
    }

    private var statusPill: some View {
        HStack(spacing: 5) {
            if game.isLive { LivePulse() }
            Text(statusText)
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .glassCard(cornerRadius: 8)
    }

    /// Everything worth knowing on one short line, for the smallest window size.
    private var compactStatus: String {
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

    private var statusText: String {
        switch game.phase {
        case .pre: return game.statusDetail
        case .final: return game.period > 4 ? "FINAL / OT" : "FINAL"
        case .halftime: return "HALFTIME"
        default: return "\(game.periodLabel) · \(game.displayClock)"
        }
    }

    // MARK: - Field

    @ViewBuilder
    private func fieldSection(width: CGFloat, density: Density) -> some View {
        let inset: CGFloat = density == .compact ? 16 : 2 * Metrics.gutter + 16
        VStack(alignment: .leading, spacing: 6) {
            if let drive = activeDrive {
                if density != .tiny {
                HStack(spacing: 6) {
                    Text(drive.isCurrent ? "Current drive" : drive.result)
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                    if density == .regular {
                        Text(drive.summary)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()

                    // Reading through a drive one click at a time is tedious, so this
                    // opens every description at once.
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            preferences.showsAllPlayText.toggle()
                        }
                    } label: {
                        Image(systemName: preferences.showsAllPlayText
                              ? "text.alignleft" : "text.justify.left")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(preferences.showsAllPlayText
                                             ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    }
                    .buttonStyle(.plain)
                    .help(preferences.showsAllPlayText
                          ? "Hide play descriptions"
                          : "Show every play description")

                    if selectedDriveID != nil {
                        Button("Latest") { withAnimation(.snappy) { selectedDriveID = nil } }
                            .font(.system(size: 9, weight: .medium))
                            .buttonStyle(.plain)
                            .foregroundStyle(.tint)
                    }
                }
                }

                FieldLadderView(
                    drive: drive,
                    offense: offense,
                    defense: defense,
                    creditsByPlay: fantasy.creditsByPlay,
                    showsAllText: preferences.showsAllPlayText,
                    width: max(width - inset, 80),
                    expandedPlayID: $expandedPlayID
                )
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .glassCard()
            } else {
                placeholder
            }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 6) {
            Image(systemName: game.phase == .pre ? "clock" : "football")
                .font(.system(size: 18))
                .foregroundStyle(.tertiary)
            Text(game.phase == .pre ? "Hasn't kicked off yet" : "Waiting for play-by-play…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .glassCard()
    }

    // MARK: - Your players in this game

    @ViewBuilder
    private var fantasySection: some View {
        let leagues = fantasy.playersByLeague(inGame: game)
        if !leagues.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Your matchup in this game")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)

                ForEach(leagues, id: \.leagueID) { league in
                    VStack(alignment: .leading, spacing: 3) {
                        // Only worth naming the league when there is more than one;
                        // otherwise it is just a redundant header.
                        if leagues.count > 1 {
                            Text(league.leagueName)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 2)
                        }
                        ForEach(league.players, id: \.player.id) { entry in
                            playerRow(entry)
                        }
                    }
                }
            }
        }
    }

    private func playerRow(_ entry: (player: RosterPlayer, isMine: Bool)) -> some View {
        HStack(spacing: 6) {
            Image(systemName: entry.isMine ? "person.fill" : "person")
                .font(.system(size: 8))
                .foregroundStyle(entry.isMine ? Color.green : Color.orange)
                .frame(width: 12)
            Text(entry.player.slot.label)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 30, alignment: .leading)
            Text(entry.player.fullName)
                .font(.system(size: 10))
                .lineLimit(1)
            Spacer()
            Text(String(format: "%.1f", entry.player.points))
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.primary.opacity(0.035))
        )
    }

    // MARK: - Drive log

    @ViewBuilder
    private var driveLogSection: some View {
        if !drives.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text("Drives")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)

                ForEach(drives) { drive in
                    DriveRowView(
                        drive: drive,
                        team: game.team(id: drive.teamID),
                        isSelected: drive.id == activeDrive?.id,
                        onSelect: {
                            withAnimation(.snappy(duration: 0.2)) {
                                selectedDriveID = drive.id
                                expandedPlayID = nil
                            }
                        }
                    )
                }
            }
        }
    }
}

/// One line in the drive log. Selecting it redraws the field above.
struct DriveRowView: View {
    let drive: Drive
    let team: TeamSide?
    let isSelected: Bool
    let onSelect: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill((team?.tint ?? .gray).legibleOnGlass(dark: scheme == .dark))
                    .frame(width: 3, height: 20)

                Text(drive.teamAbbreviation)
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 30, alignment: .leading)

                VStack(alignment: .leading, spacing: 1) {
                    Text(drive.isCurrent ? "In progress" : drive.result)
                        .font(.system(size: 10, weight: drive.isScore ? .semibold : .regular))
                        .foregroundStyle(drive.isScore ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.primary))
                    Text(drive.summary)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                if drive.isCurrent { LivePulse() }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(.rect)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.primary.opacity(isSelected ? 0.09 : (isHovering ? 0.05 : 0)))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
