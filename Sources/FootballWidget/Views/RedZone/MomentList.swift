import SwiftUI
import FootballCore

/// The whip-around: the last few key moments from every game, newest first. Tapping one
/// features its game.
struct MomentList: View {
    let moments: [Moment]
    let onPick: (String) -> Void
    let onOpen: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(moments) { moment in
                MomentRow(moment: moment)
                    .contentShape(Rectangle())
                    .onTapGesture { onPick(moment.gameID) }
                    .contextMenu {
                        Button("Open in Its Own Window") { onOpen(moment.gameID) }
                    }
            }
        }
        .padding(.vertical, 1)
    }
}

struct MomentRow: View {
    let moment: Moment

    /// "2:51" — the afternoon is understood.
    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm"
        return formatter
    }()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            // When it happened by the time of day. The game clock ("Q2 6:19", "HALF") said
            // nothing about how long ago that was, so an old score looked new; it is in
            // the tooltip instead. Not "2m ago", which would redraw every row every second.
            Text(Self.time.string(from: moment.at))
                .font(.system(size: 8.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: 28, alignment: .leading)
            Image(systemName: glyph)
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 9)
            Text(moment.title)
                .font(.system(size: 9, weight: moment.kind == .scoring ? .semibold : .regular))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .frame(minHeight: 13)
        .help([moment.clock, moment.detail ?? moment.title].joined(separator: " · "))
    }

    private var glyph: String {
        switch moment.kind {
        case .scoring: return "football.fill"
        case .turnover: return "arrow.triangle.2.circlepath"
        case .redZone: return "flag.fill"
        case .final: return "flag.checkered"
        }
    }

    private var color: Color {
        switch moment.kind {
        case .scoring: return .green
        case .turnover: return .orange
        case .redZone: return .red
        case .final: return .secondary
        }
    }
}

/// Every live score in one line. Tapping one features that game.
struct ScoreStrip: View {
    let games: [Game]
    let featuredID: String?
    let pickedID: String?
    let onPick: (String) -> Void
    let onOpen: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(games) { game in
                    chip(game)
                        .onTapGesture { onPick(game.id) }
                        .contextMenu {
                            Button("Open in Its Own Window") { onOpen(game.id) }
                        }
                        .help("Watch \(game.shortName) here")
                }
            }
            .padding(.horizontal, 6)
        }
        .frame(height: 17)
    }

    private func chip(_ game: Game) -> some View {
        let inRedZone = game.situation?.isRedZone == true && game.teamWithPossession != nil
        let featured = game.id == featuredID
        return HStack(spacing: 3) {
            if game.id == pickedID {
                Image(systemName: "pin.fill").font(.system(size: 6))
            } else if inRedZone {
                Circle().fill(.red).frame(width: 4, height: 4)
            }
            Text("\(game.away.abbreviation) \(game.away.score)-\(game.home.score) \(game.home.abbreviation)")
                .font(.system(size: 8.5, weight: featured ? .bold : .semibold))
                .monospacedDigit()
            Text(game.phase == .halftime ? "H" : game.periodLabel)
                .font(.system(size: 7, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(
            Capsule().fill(featured ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1))
        )
    }
}
