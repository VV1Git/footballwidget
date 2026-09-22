import SwiftUI
import FootballCore

/// The dropdown panel. Shows the slate, or one game when you click into it.
struct PanelRootView: View {
    @Environment(GameStore.self) private var store
    @Environment(\.openSettings) private var openSettings

    @Environment(FantasyStore.self) private var fantasy
    @Environment(Preferences.self) private var preferences
    @State private var selectedGameID: String?
    @State private var showingFantasy = false
    /// The panel's window outlives its closing, and SwiftUI drives a `repeatForever`
    /// animation frame by frame on the main thread even off screen — which for the
    /// refresh spinner meant every poll, all day. It only spins while the panel is open.
    @State private var isShown = false
    @Namespace private var glassNamespace

    private var selectedGame: Game? {
        guard let selectedGameID else { return nil }
        return store.game(id: selectedGameID)
    }

    var body: some View {
        // Deliberately NOT wrapped in a GlassEffectContainer. The container composites
        // every glass surface inside it together, which drew the glass-backed game rows
        // over the footer's background no matter how opaque that background was — the
        // rows appeared to scroll through the bottom bar. The container now lives inside
        // GameListView, around the rows alone.
        VStack(spacing: 0) {
            Group {
                if showingFantasy {
                    FantasyMatchupView(onBack: {
                        withAnimation(.snappy(duration: 0.25)) { showingFantasy = false }
                    })
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                } else if let game = selectedGame {
                    GameDetailView(
                        game: game,
                        detail: store.detail(id: game.id),
                        onBack: { select(nil) },
                        onPin: { pin(game) }
                    )
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                } else {
                    GameListView(onSelect: { select($0.id) })
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            // An explicit height for the scrolling half, so it physically cannot
            // extend into the footer's space.
            .frame(height: contentHeight)
            .clipped()

            Divider().opacity(0.4)

            footer
                .frame(height: Self.footerHeight)
                .background(.background)
        }
        // A definite height, not just a maximum. MenuBarExtra's window sizes itself to
        // its content, and under that proposal a `maxHeight`-only frame lets the game
        // list's ScrollView collapse to zero — leaving a panel showing nothing but the
        // header and the footer.
        .frame(width: Metrics.panelWidth, height: panelHeight)
        .onAppear {
            isShown = true
            store.focus = selectedGameID.map { .detail(gameID: $0) } ?? .list
        }
        .onDisappear {
            isShown = false
            store.focus = .closed
        }
    }

    /// Everything above the divider and the footer.
    private var contentHeight: CGFloat {
        max(panelHeight - Self.footerHeight - 1, 80)
    }

    /// Tall enough for the content, capped so a full slate still fits on screen.
    /// Collapsing a section shrinks the panel with it rather than leaving dead space.
    private var panelHeight: CGFloat {
        if showingFantasy || selectedGame != nil { return Metrics.panelMaxHeight }
        guard !store.games.isEmpty else { return 190 }

        let sections = GameSections.build(store.games, favorites: preferences.favorites)
        var height: CGFloat = 8 + 12                       // list top and bottom padding
        for (index, section) in sections.enumerated() {
            height += Self.sectionHeaderHeight
            if !preferences.isCollapsed(section.kind) {
                let rows = CGFloat(section.games.count)
                height += Metrics.rowSpacing
                height += rows * Self.rowHeight + (rows - 1) * Metrics.rowSpacing
            }
            if index < sections.count - 1 { height += 10 }  // spacing between sections
        }
        height += Self.footerHeight
        return min(max(height, 150), Metrics.panelMaxHeight)
    }

    private static let sectionHeaderHeight: CGFloat = 22
    private static let footerHeight: CGFloat = 31

    /// One game row: two team lines plus the card's vertical padding.
    private static let rowHeight: CGFloat = 60

    private func select(_ id: String?) {
        withAnimation(.snappy(duration: 0.25)) { selectedGameID = id }
        store.focus = id.map { .detail(gameID: $0) } ?? .list
        if let id { Task { await store.refreshDetail(id: id) } }
    }

    private func pin(_ game: Game) {
        PinnedGameWindowController.shared.show(gameID: game.id, store: store, fantasy: fantasy)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .help(error)
            } else {
                Text(updatedText)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if fantasy.isConfigured && !showingFantasy {
                Button {
                    withAnimation(.snappy(duration: 0.25)) { showingFantasy = true }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 8))
                        if let matchup = fantasy.matchup {
                            Text(matchup.compactScore)
                                .font(.system(size: 9, weight: .semibold))
                                .monospacedDigit()
                            // Your chance of winning, while there is still one to have.
                            if let chance = fantasy.winProbability, !chance.isSettled {
                                Text(chance.myPercentText)
                                    .font(.system(size: 9, weight: .medium))
                                    .monospacedDigit()
                                    .foregroundStyle(.tertiary)
                            }
                        } else {
                            Text("Fantasy").font(.system(size: 9, weight: .medium))
                        }
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Your fantasy matchup")
            }

            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(store.isRefreshing && isShown ? 360 : 0))
                    .animation(store.isRefreshing && isShown
                               ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                               : .default,
                               value: store.isRefreshing && isShown)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Refresh now")

            Button {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Settings")

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Quit Football")
        }
        .padding(.horizontal, Metrics.gutter)
    }

    private var updatedText: String {
        guard let updated = store.lastUpdated else { return "Loading…" }
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm:ss a"
        return "Updated \(formatter.string(from: updated))"
    }
}
