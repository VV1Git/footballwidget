import SwiftUI
import FootballCore

/// The field map: one row per play, every row sharing a single yard scale so play
/// order reads top-to-bottom while field position reads left-to-right.
///
/// The yard grid is drawn once behind all the rows rather than per row, so the plays
/// sit on a continuous field instead of a stack of separate charts.
struct FieldLadderView: View {
    let drive: Drive
    let offense: TeamSide?
    let defense: TeamSide?
    /// Play id → rostered players it named. Empty when no fantasy league is connected.
    var creditsByPlay: [String: [PlayAttribution.Credit]] = [:]
    /// Show every description at once instead of opening them individually.
    var showsAllText: Bool = false
    /// The width the parent has offered, so the height can be worked out before the
    /// GeometryReader reports back.
    var width: CGFloat = Metrics.panelWidth
    @Binding var expandedPlayID: String?

    @Environment(\.colorScheme) private var scheme

    private var rows: [LadderRow] { FieldGeometry.rows(for: drive) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if rows.isEmpty {
                emptyState
            } else {
                GeometryReader { proxy in
                    let layout = Layout(totalWidth: proxy.size.width)
                    ladder(layout: layout)
                }
                .frame(height: contentHeight(Layout(totalWidth: width)))
            }
        }
    }

    private func contentHeight(_ layout: Layout) -> CGFloat {
        let base = headerHeight(layout) + (drive.outcome != nil ? Layout.driveEndHeight : 0)
        return rows.reduce(base) { total, row in
            let scoring = (creditsByPlay[row.id]?.contains { $0.points != nil } ?? false)
                && layout.showsMeta
            let chips = scoring ? Layout.chipRowHeight : 0
            // Only an opened row needs room, and it needs as much as its text wraps to.
            let isOpen = expandedPlayID == row.id || showsAllText
            let opened = isOpen ? expandedHeight(for: row, layout: layout) : 0
            return total + layout.rowHeight + chips + opened
        }
    }

    /// Play descriptions run from a few words to a full sentence with tacklers and a
    /// penalty clause, so the opened row is measured from the text rather than given a
    /// fixed allowance that would clip the long ones.
    private func expandedHeight(for row: LadderRow, layout: Layout) -> CGFloat {
        let text = row.play.text.isEmpty ? row.play.typeText : row.play.text
        guard !text.isEmpty else { return 0 }
        let usable = max(layout.totalWidth - layout.trackOrigin - 8, 80)
        let charactersPerLine = max(Int(usable / 4.9), 12)   // ~4.9pt per character at 9pt
        let lines = max(1, Int((Double(text.count) / Double(charactersPerLine)).rounded(.up)))
        return CGFloat(min(lines, 5)) * 11.5 + 8
    }

    private func headerHeight(_ layout: Layout) -> CGFloat {
        layout.showsYardNumbers ? 18 : 6
    }

    // MARK: - Ladder

    private func ladder(layout: Layout) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if layout.showsYardNumbers {
                scaleHeader(layout: layout)
                    .frame(height: headerHeight(layout))
            } else {
                Color.clear.frame(height: headerHeight(layout))
            }

            ZStack(alignment: .topLeading) {
                FieldGrid(layout: layout, offense: offense, defense: defense, scheme: scheme)

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        LadderRowView(
                            row: row,
                            layout: layout,
                            offense: offense,
                            defense: defense,
                            isExpanded: expandedPlayID == row.id || showsAllText,
                            credits: creditsByPlay[row.id] ?? [],
                            onTap: { toggle(row) }
                        )
                    }

                    if let outcome = drive.outcome {
                        driveEnd(outcome, layout: layout)
                    }
                }
            }
        }
    }

    /// A drive ending used to be signalled only by the next play changing colour,
    /// which does not tell you what happened or why the other team has the ball.
    private func driveEnd(_ outcome: String, layout: Layout) -> some View {
        HStack(spacing: 5) {
            Image(systemName: endSymbol)
                .font(.system(size: 8, weight: .bold))
            Text(outcome.uppercased())
                .font(.system(size: 9, weight: .bold))
                .lineLimit(1)
            if let handoff = handoffText {
                Text(handoff)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(endTint)
        .padding(.leading, layout.showsIndex ? layout.leftEdge : 2)
        .padding(.trailing, 4)
        .frame(height: Layout.driveEndHeight, alignment: .center)
    }

    private var endSymbol: String {
        if drive.isScore { return "star.fill" }
        if drive.endedInTurnover { return "arrow.uturn.left" }
        return "arrow.right.to.line"
    }

    private var endTint: Color {
        if drive.isScore { return .orange }
        if drive.endedInTurnover { return .red }
        return .secondary
    }

    /// Who has the ball now, which is the part that was missing.
    private var handoffText: String? {
        guard let defense, !drive.isScore else { return nil }
        return "· \(defense.abbreviation) ball"
    }

    private func toggle(_ row: LadderRow) {
        withAnimation(.snappy(duration: 0.22)) {
            expandedPlayID = expandedPlayID == row.id ? nil : row.id
        }
    }

    // MARK: - Header

    private func scaleHeader(layout: Layout) -> some View {
        ZStack(alignment: .leading) {
            // Team labels sit above their own end zones.
            if layout.showsEndZoneLabels {
                Text(offense?.abbreviation ?? "")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle((offense?.tint ?? .secondary).legibleOnGlass(dark: scheme == .dark))
                    .fixedSize()
                    .frame(width: layout.endZoneWidth + 16)
                    .offset(x: layout.leftEdge - 8)

                Text(defense?.abbreviation ?? "")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle((defense?.tint ?? .secondary).legibleOnGlass(dark: scheme == .dark))
                    .fixedSize()
                    .frame(width: layout.endZoneWidth + 16)
                    .offset(x: layout.trackTrailingEdge - 8)
            }

            ForEach(layout.visibleYardTicks, id: \.x) { tick in
                Text(tick.label)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16)
                    .offset(x: layout.x(for: tick.x) - 8)
            }
        }
    }

    private var emptyState: some View {
        HStack(spacing: 6) {
            Image(systemName: "football")
            Text("No plays yet on this drive")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 18)
    }
}

// MARK: - Layout

/// Where the columns sit. Shared by the grid and every row so the bars line up with
/// the yard lines exactly.
///
/// Everything scales with the available width so the map still reads in a torn-off
/// window shrunk down to a corner of the screen: below ~300pt the per-play detail
/// column is dropped and below ~230pt the play numbers go too, leaving the field
/// itself, which is the part worth keeping.
struct Layout {
    let totalWidth: CGFloat

    static let chipRowHeight: CGFloat = 15
    static let driveEndHeight: CGFloat = 18

    /// Rows are a click target as well as a picture, so they do not go below a size
    /// that is comfortable to hit — a 13pt row was fiddly even with a steady hand.
    var rowHeight: CGFloat {
        if totalWidth < 230 { return 20 }
        if totalWidth < 300 { return 22 }
        return 24
    }

    var showsMeta: Bool { totalWidth >= 250 }
    /// The play-type glyph is the first thing to go: "1st & 10" earns its space, a
    /// small icon repeating the same information does not.
    var showsPlayIcon: Bool { totalWidth >= 330 }
    var showsIndex: Bool { totalWidth >= 230 }
    var showsYardNumbers: Bool { totalWidth >= 200 }
    /// Team abbreviations over the end zones need about three characters' worth of
    /// room; below that they truncate to "S…", which tells you nothing.
    var showsEndZoneLabels: Bool { totalWidth >= 320 }

    var indexWidth: CGFloat { showsIndex ? 16 : 0 }
    var endZoneWidth: CGFloat { totalWidth < 260 ? 5 : 9 }

    var metaWidth: CGFloat {
        guard showsMeta else { return 0 }
        if totalWidth > 460 { return 150 }
        if totalWidth >= 330 { return 112 }
        // Without the icon there is room for the text and the chevron to coexist;
        // squeezing to 85 truncated "1st & 10" to "1st &…".
        return 100
    }

    var spacing: CGFloat { totalWidth < 260 ? 3 : 5 }

    var leftEdge: CGFloat { indexWidth + (showsIndex ? spacing : 0) }
    var trackOrigin: CGFloat { leftEdge + endZoneWidth }
    var trackWidth: CGFloat {
        let trailing = endZoneWidth + (showsMeta ? spacing + metaWidth : 0)
        return max(40, totalWidth - trackOrigin - trailing)
    }
    var trackTrailingEdge: CGFloat { trackOrigin + trackWidth }
    var metaOrigin: CGFloat { trackTrailingEdge + endZoneWidth + spacing }

    /// Yard numbers every ten yards need roughly 16pt each; when the field is squeezed
    /// into a narrow window they collide, so only every twentieth yard and the 50 are
    /// labelled. The stripes stay every five yards either way.
    var visibleYardTicks: [(x: Double, label: String)] {
        let all = FieldGeometry.yardTicks
        guard trackWidth < 200 else { return all }
        // Every twentieth yard only. Keeping the 50 as well put it ten yards from each
        // 40, which collided again.
        return all.filter { Int(($0.x * 100).rounded()) % 20 == 0 }
    }

    /// Normalized 0...1 field position to a point offset.
    func x(for normalized: Double) -> CGFloat {
        trackOrigin + trackWidth * CGFloat(min(max(normalized, 0), 1))
    }
}

// MARK: - Grid

private struct FieldGrid: View {
    let layout: Layout
    let offense: TeamSide?
    let defense: TeamSide?
    let scheme: ColorScheme

    var body: some View {
        Canvas { context, size in
            let track = CGRect(x: layout.trackOrigin, y: 0,
                               width: layout.trackWidth, height: size.height)

            // Playing surface.
            context.fill(
                Path(roundedRect: track, cornerRadius: 2),
                with: .color(.primary.opacity(scheme == .dark ? 0.045 : 0.035))
            )

            // Five-yard stripes, with the 50 called out.
            for line in FieldGeometry.minorLines {
                let x = layout.x(for: line)
                let isMidfield = abs(line - 0.5) < 0.001
                let isTen = (line * 100).truncatingRemainder(dividingBy: 10) == 0
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(
                    path,
                    with: .color(.primary.opacity(isMidfield ? 0.22 : (isTen ? 0.13 : 0.06))),
                    lineWidth: isMidfield ? 1 : 0.5
                )
            }

            // End zones, in each team's color.
            let left = CGRect(x: layout.leftEdge, y: 0,
                              width: layout.endZoneWidth, height: size.height)
            let right = CGRect(x: layout.trackTrailingEdge, y: 0,
                               width: layout.endZoneWidth, height: size.height)
            context.fill(Path(roundedRect: left, cornerRadius: 2),
                         with: .color((offense?.tint ?? .gray).opacity(0.30)))
            context.fill(Path(roundedRect: right, cornerRadius: 2),
                         with: .color((defense?.tint ?? .gray).opacity(0.30)))

            // Goal lines.
            for x in [layout.trackOrigin, layout.trackTrailingEdge] {
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(path, with: .color(.primary.opacity(0.28)), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }
}
