import SwiftUI
import FootballCore

/// A single play on the ladder: the bar showing where the ball went, plus a compact
/// label. Clicking reveals the full description.
struct LadderRowView: View {
    let row: LadderRow
    let layout: Layout
    let offense: TeamSide?
    let defense: TeamSide?
    let isExpanded: Bool
    /// Rostered players this play named, and what it was worth. Empty when no league
    /// is connected.
    var credits: [PlayAttribution.Credit] = []
    let onTap: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onTap) {
            ZStack(alignment: .leading) {
                if isHovering || isExpanded {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(.primary.opacity(isHovering ? 0.10 : 0.06))
                }

                if layout.showsIndex {
                    sequenceBadge
                        .frame(width: layout.indexWidth, alignment: .trailing)
                }

                bar

                if layout.showsMeta {
                    meta
                        .frame(width: layout.metaWidth, alignment: .leading)
                        .offset(x: layout.metaOrigin)
                }
            }
            .frame(height: layout.rowHeight)
            .overlay(alignment: .trailing) {
                // Only when there is no meta column; otherwise the chevron lives
                // inside it, after the yardage, where it cannot cover anything.
                if hasDescription && !layout.showsMeta {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.secondary)
                        .opacity(isHovering ? 1 : (isExpanded ? 0.8 : 0.35))
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .padding(.trailing, 1)
                }
            }
            .contentShape(.rect)
            .onHover { isHovering = $0 }
            .help(hasDescription
                  ? (isExpanded ? "Hide play description" : descriptionText)
                  : "")
            }
            .buttonStyle(.plain)

            if !scoringCredits.isEmpty && layout.showsMeta {
                fantasyChips
                    .padding(.leading, layout.trackOrigin + 4)
                    .padding(.top, -3)
                    .padding(.bottom, 1)
            }

            // Hidden until the play is clicked, so a long drive stays scannable.
            if isExpanded && !descriptionText.isEmpty {
                Text(descriptionText)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, layout.showsIndex ? layout.trackOrigin : 4)
                    .padding(.trailing, 4)
                    .padding(.bottom, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        // A chip hangs below the play it belongs to, which on a dense ladder reads as
        // belonging to the row underneath. Tinting the pair together removes the doubt.
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(scoringCredits.isEmpty
                      ? Color.clear
                      : (scoringCredits.contains { $0.isMine } ? Color.green : Color.orange)
                        .opacity(0.07))
        )
    }

    /// Shows whose player was involved and, once the points have landed, what the
    /// play was worth to that lineup.
    /// ESPN's own wording, which already reads as "S.Darnold pass short middle to
    /// J.Smith-Njigba for 13 yards".
    private var descriptionText: String {
        row.play.text.isEmpty ? row.play.typeText : row.play.text
    }

    private var hasDescription: Bool { !descriptionText.isEmpty }

    /// Only players who actually earned something on this play. At most two, so a
    /// quarterback-to-receiver connection fits but a crowded play does not wrap.
    private var scoringCredits: [PlayAttribution.Credit] {
        Array(credits.filter { $0.points != nil }.prefix(2))
    }

    private var fantasyChips: some View {
        HStack(spacing: 4) {
            ForEach(scoringCredits, id: \.playerID) { credit in
                HStack(spacing: 3) {
                    Image(systemName: credit.isMine ? "person.fill" : "person")
                        .font(.system(size: 6))
                    Text(shortName(credit.playerName))
                        .font(.system(size: 8, weight: .medium))
                    if let points = credit.points {
                        Text(pointsLabel(points))
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .monospacedDigit()
                    }
                }
                .foregroundStyle(credit.isMine ? Color.green : Color.orange)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    Capsule().fill((credit.isMine ? Color.green : Color.orange).opacity(0.14))
                )
            }
        }
    }

    /// "Ja'Marr Chase" → "J. Chase", so several chips fit on one row.
    private func shortName(_ name: String) -> String {
        let parts = name.split(separator: " ")
        guard parts.count > 1, let initial = parts.first?.first else { return name }
        return "\(initial). \(parts.dropFirst().joined(separator: " "))"
    }

    private func pointsLabel(_ points: Double) -> String {
        let rounded = (points * 10).rounded() / 10
        return rounded < 0 ? String(format: "%.1f", rounded) : "+" + String(format: "%.1f", rounded)
    }

    // MARK: - Pieces

    private var sequenceBadge: some View {
        Group {
            if row.isDriveStart {
                Image(systemName: "flag.fill").font(.system(size: 7))
            } else if row.play.isScoring {
                Image(systemName: "star.fill").font(.system(size: 7))
            } else {
                Text("\(displayIndex)")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(row.play.isScoring ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
    }

    /// Drive-start markers are not plays, so the numbering counts snaps only.
    private var displayIndex: Int { row.number ?? 0 }

    @ViewBuilder
    private var bar: some View {
        let startX = layout.x(for: row.startX)
        let endX = layout.x(for: row.endX)
        let low = min(startX, endX)
        let width = max(abs(endX - startX), 2)

        if row.isDriveStart {
            // Where the drive began — a tick, not a movement.
            Capsule()
                .fill(.secondary.opacity(0.5))
                .frame(width: 2, height: layout.rowHeight * 0.55)
                .offset(x: startX - 1)
        } else if row.isNoGain {
            Circle()
                .fill(barColor.opacity(0.85))
                .frame(width: 5, height: 5)
                .offset(x: startX - 2.5)
        } else {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(barColor.gradient)
                    .frame(width: width, height: max(layout.rowHeight * 0.35, 5))
                    .offset(x: low)

                // Arrowhead in the direction the ball actually travelled.
                Image(systemName: row.isBackwards ? "arrowtriangle.left.fill" : "arrowtriangle.right.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(barColor)
                    .offset(x: endX - (row.isBackwards ? 5 : 1))

                // Anchor at the snap so a loss reads as "went backwards from here".
                Capsule()
                    .fill(.primary.opacity(0.35))
                    .frame(width: 1.5, height: layout.rowHeight * 0.55)
                    .offset(x: startX - 0.75)
            }
        }
    }

    private var barColor: Color {
        let dark = scheme == .dark
        if row.flipsFrame { return defense?.legibleTint(dark: dark) ?? Color.red.legibleOnGlass(dark: dark) }
        if row.play.isScoring { return .orange }
        if row.isBackwards { return .red.opacity(0.75) }
        return offense?.legibleTint(dark: dark) ?? Color.accentColor.legibleOnGlass(dark: dark)
    }

    private var meta: some View {
        HStack(spacing: 4) {
            if layout.showsPlayIcon {
                Image(systemName: playSymbol)
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .frame(width: 10)
            }

            Text(downDistance)
                .font(.system(size: 9, weight: .regular))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 2)

            Text(yardageLabel)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(yardageColor)
                .lineLimit(1)
                .fixedSize()

            // Nothing else signals that a row opens, so the chevron sits here and
            // turns once it is open.
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.secondary)
                .opacity(hasDescription ? (isHovering ? 1 : (isExpanded ? 0.8 : 0.35)) : 0)
                .rotationEffect(.degrees(isExpanded ? 0 : -90))
                .frame(width: 8)
        }
        .padding(.trailing, 2)
    }

    /// Worked out in `LadderRow`, where the labels for every kind of play can be tested.
    private var downDistance: String { row.situationLabel }

    private var yardageLabel: String { row.resultLabel }

    private var yardageColor: Color {
        if row.play.isScoring { return .orange }
        if row.play.yards < 0 { return .red }
        if row.play.yards == 0 { return .secondary }
        return .primary
    }

    private var playSymbol: String {
        if row.isDriveStart { return "flag" }
        if row.flipsFrame { return "arrow.uturn.left" }
        if row.play.isPenalty { return "flag.slash" }
        switch row.play.typeID {
        case "5": return "figure.american.football"       // Rush
        case "24", "3", "51": return "arrow.up.forward"    // Pass
        case "7": return "xmark.circle"                    // Sack
        case "52": return "arrow.up.to.line"               // Punt
        case "59", "60": return "figure.kickboxing"        // Field goal, good or missed
        case "67", "68": return "star"                     // Touchdown
        default: return "circle"
        }
    }
}
