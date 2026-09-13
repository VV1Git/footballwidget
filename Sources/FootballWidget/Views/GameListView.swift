import SwiftUI
import FootballCore

/// The slate, split into what is on today and what is coming later this week.
struct GameListView: View {
    let onSelect: (Game) -> Void

    @Environment(GameStore.self) private var store
    @Environment(Preferences.self) private var preferences

    private var sections: [GameSection] {
        GameSections.build(store.games, favorites: preferences.favorites)
    }

    var body: some View {
        Group {
            if store.games.isEmpty {
                emptyState
            } else {
                ScrollView {
                    // Glass blending is scoped to the rows. Wrapping the whole panel in
                    // this composited the rows above the footer's background, so they
                    // showed through the bottom bar.
                    GlassEffectContainer(spacing: Metrics.rowSpacing) {
                    // A plain VStack, not a Lazy one. A LazyVStack only materialises
                    // rows once its container has a definite height to work with, and
                    // inside a menu bar panel that sizes itself to its content it can
                    // end up rendering nothing at all.
                    VStack(spacing: 10) {
                        ForEach(sections) { section in
                            sectionView(section)
                        }
                    }
                    }
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                }
                .scrollIndicators(.never)
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func sectionView(_ section: GameSection) -> some View {
        let collapsed = preferences.isCollapsed(section.kind)

        VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
            sectionHeader(section, collapsed: collapsed)

            if !collapsed {
                ForEach(section.games) { game in
                    GameRowView(
                        game: game,
                        onSelect: { onSelect(game) },
                        onToggleFavorite: { toggleFavorite($0) }
                    )
                    .transition(.opacity)
                }
            }
        }
    }

    private func sectionHeader(_ section: GameSection, collapsed: Bool) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.22)) {
                preferences.toggleSection(section.kind)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))

                Text(section.title)
                    .font(.system(size: 11, weight: .semibold))

                if section.liveCount > 0 {
                    HStack(spacing: 3) {
                        LivePulse()
                        Text("\(section.liveCount) live")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .foregroundStyle(.red)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.red.opacity(0.14), in: Capsule())
                }

                Spacer()

                Text(section.countLabel)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .help(collapsed ? "Show \(section.title.lowercased())" : "Hide \(section.title.lowercased())")
    }

    private func toggleFavorite(_ abbreviation: String) {
        withAnimation(.snappy(duration: 0.25)) {
            preferences.toggleFavorite(abbreviation)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 7) {
            Image(systemName: "football")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text(store.errorMessage == nil ? "No NFL games scheduled" : "Couldn't reach ESPN")
                .font(.system(size: 12, weight: .medium))
            if let next = store.nextKickoff {
                Text("Next kickoff \(next.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 42)
    }
}
