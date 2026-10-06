import SwiftUI
import FootballCore

/// The featured game in four short lines: the score and clock, who has the ball and
/// where (or why play is stopped), the field, and the last play with what it was worth
/// to your lineup.
struct SpotlightCard: View {
    let game: Game
    /// The window's buttons, at the end of the score line — there is no separate title bar.
    var controls: RedZoneControls?
    /// Told the score line's natural width, padding included, which the card takes as
    /// its own.
    var onLineWidth: ((CGFloat) -> Void)?

    /// The natural widths of the score line's two halves, measured in place.
    @State private var contentWidth: CGFloat = 0
    @State private var controlsWidth: CGFloat = 0

    @Environment(FantasyStore.self) private var fantasy
    @Environment(RedZoneStore.self) private var redZone
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // Two sections of glass; the card's container blends them into one surface.
        // See `RedZoneSection`.
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                scoreLine
                situationLine
                if showsField {
                    MiniFieldBar(game: game)
                        .frame(height: 5)
                }
            }
            .padding(.horizontal, 6)
            .padding(.top, 3)
            .padding(.bottom, 2)
            .modifier(RedZoneSection(edge: topEdge))

            // The whole play, wrapped: cut off it lost the end — the yardage,
            // "TOUCHDOWN" — which is the part worth reading.
            if lastPlay != nil || !chips.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    if let lastPlay {
                        Text(lastPlay)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !chips.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(chips, id: \.playerID) { credit in
                                CreditChip(credit: credit)
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 4)
                .modifier(RedZoneSection(edge: .middle))
            }
        }
    }

    /// The top section rounds its upper corners; the card itself begins here.
    private var topEdge: RedZoneSection.Edge { .top }

    /// The line packed tight — the spacer at its minimum — plus the card's padding.
    private func reportWidth() {
        guard contentWidth > 0, controlsWidth > 0 else { return }
        onLineWidth?(contentWidth + 3 + 6 + 3 + controlsWidth + 12)
    }

    /// Teams, score and clock: everything on the score line but the buttons.
    @ViewBuilder
    private var scoreLineContent: some View {
        TeamMark(team: game.away)
        Text("\(game.away.score)")
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .monospacedDigit()
            .fixedSize()
        Text("–")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
        Text("\(game.home.score)")
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .monospacedDigit()
            .fixedSize()
        TeamMark(team: game.home)
        if game.isLive { LivePulse() }
        Text(clockText)
            .font(.system(size: 9, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .fixedSize()
    }

    private var scoreLine: some View {
        HStack(spacing: 3) {
            HStack(spacing: 3) { scoreLineContent }
                .fixedSize()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                    contentWidth = $0
                    reportWidth()
                }
            Spacer(minLength: 6)
            controls
                .fixedSize()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                    controlsWidth = $0
                    reportWidth()
                }
        }
        .frame(height: 16)
        .contentShape(Rectangle())
        .modifier(RedZoneDrag(controller: RedZoneWindowController.shared))
    }

    /// Who has the ball and where, with the reason this game is on. While play is
    /// stopped there is no ball to place, so the line says what the stoppage is.
    @ViewBuilder
    private var situationLine: some View {
        HStack(spacing: 3) {
            if let team = game.teamWithPossession, inPlay {
                Image(systemName: "football.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(team.legibleTint(dark: scheme == .dark))
                Text(team.abbreviation)
                    .font(.system(size: 9, weight: .semibold))
                if let text = game.situation?.downDistanceText, !text.isEmpty {
                    Text(text)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if game.situation?.isRedZone == true {
                    Text("RZ")
                        .font(.system(size: 7.5, weight: .heavy))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 3)
                        .background(Color.red.opacity(0.14), in: Capsule())
                }
            } else if !redZone.spotlightReason.isEmpty, !inPlay {
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                Text(redZone.spotlightReason)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if inPlay, !redZone.spotlightReason.isEmpty {
                Text(redZone.spotlightReason)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    /// The ranker's word on it: a stoppage or a break is not "in play".
    private var inPlay: Bool {
        redZone.ranked.first { $0.id == game.id }?.inPlay ?? (game.phase == .live)
    }

    private var showsField: Bool {
        guard inPlay, let situation = game.situation else { return false }
        return FieldPosition.yardsToGoal(situation, in: game) != nil
    }

    private var clockText: String {
        switch game.phase {
        case .final: return game.period > 4 ? "FINAL/OT" : "FINAL"
        case .halftime: return "HALF"
        default: return game.displayClock.isEmpty ? game.periodLabel : "\(game.periodLabel) \(game.displayClock)"
        }
    }

    /// The last snap, never a clock event: "Official Timeout at 07:08" said nothing the
    /// stoppage line does not.
    private var lastPlay: String? {
        guard let situation = game.situation, let text = situation.lastPlayText, !text.isEmpty,
              !FieldGeometry.administrativeTypeIDs.contains(situation.lastPlayTypeID ?? "")
        else { return nil }
        return RedZoneText.lastPlay(text)
    }

    /// Points your lineup (or your opponent's) took from the last play: from the play
    /// feed once it has the play, and scored straight off the scoreboard until then.
    private var chips: [PlayAttribution.Credit] {
        guard let id = game.situation?.lastPlayID else { return [] }
        let scored = fantasy.credits(forPlay: id).filter { $0.points != nil }
        return Array((scored.isEmpty ? fantasy.provisionalCredits(for: game) : scored).prefix(2))
    }
}

/// A small logo and the abbreviation.
private struct TeamMark: View {
    let team: TeamSide

    var body: some View {
        HStack(spacing: 3) {
            TeamLogo(url: team.logoURL, fallbackTint: team.tint)
                .frame(width: 11, height: 11)
            Text(team.abbreviation)
                .font(.system(size: 10, weight: .semibold))
        }
        .fixedSize()
    }
}

private struct CreditChip: View {
    let credit: PlayAttribution.Credit

    var body: some View {
        let color = credit.isMine ? Color.green : Color.orange
        HStack(spacing: 2) {
            Text(shortName)
                .font(.system(size: 8, weight: .medium))
            if let points = credit.points {
                Text(points < 0 ? String(format: "%.1f", points) : String(format: "+%.1f", points))
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(color)
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(Capsule().fill(color.opacity(0.14)))
    }

    /// "Ja'Marr Chase" → "Chase", so two fit beside the play.
    private var shortName: String {
        credit.playerName.split(separator: " ").dropFirst().joined(separator: " ")
            .nonEmpty ?? credit.playerName
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// The field from the offense's point of view, attacking right: end zones in team
/// colours, the red zone shaded, the line of scrimmage and the first-down marker. The
/// scoreboard does not say which end each team defends, so this does not try to.
struct MiniFieldBar: View {
    let game: Game

    var body: some View {
        Canvas { context, size in
            let width = size.width
            let height = size.height
            func x(yardsToGoal: Int) -> CGFloat {
                CGFloat(10 + (100 - yardsToGoal)) / 120 * width
            }
            let field = CGRect(origin: .zero, size: size)
            context.fill(Path(roundedRect: field, cornerRadius: 2), with: .color(.green.opacity(0.16)))

            let endZone = width * 10 / 120
            let offense = game.teamWithPossession
            let defense = offense.flatMap { team in [game.home, game.away].first { $0.id != team.id } }
            context.fill(Path(CGRect(x: 0, y: 0, width: endZone, height: height)),
                         with: .color((offense?.tint ?? .gray).opacity(0.45)))
            context.fill(Path(CGRect(x: width - endZone, y: 0, width: endZone, height: height)),
                         with: .color((defense?.tint ?? .gray).opacity(0.45)))
            context.fill(Path(CGRect(x: x(yardsToGoal: 20), y: 0,
                                     width: width - endZone - x(yardsToGoal: 20), height: height)),
                         with: .color(.red.opacity(0.10)))

            guard let situation = game.situation,
                  let line = FieldPosition.yardsToGoal(situation, in: game) else { return }
            if let marker = FieldPosition.firstDownYardsToGoal(situation, in: game) {
                context.fill(Path(CGRect(x: x(yardsToGoal: marker) - 0.75, y: 0, width: 1.5, height: height)),
                             with: .color(.yellow))
            }
            let scrimmage = x(yardsToGoal: line)
            context.fill(Path(CGRect(x: scrimmage - 0.75, y: 0, width: 1.5, height: height)),
                         with: .color(.blue))
        }
    }
}
