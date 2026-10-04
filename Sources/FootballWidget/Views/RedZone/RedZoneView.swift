import SwiftUI
import FootballCore

/// The RedZone window's content: the pill or the full view, pinned to the corner the
/// window is anchored to.
struct RedZoneRootView: View {
    let controller: RedZoneWindowController

    @Environment(Preferences.self) private var preferences

    var body: some View {
        let corner = ScreenCorner(rawValue: preferences.redZoneCorner) ?? .bottomRight
        Group {
            if preferences.redZoneMini {
                RedZonePill(controller: controller)
                    .fixedSize()
                    .onGeometryChange(for: CGSize.self) { $0.size } action: {
                        controller.pillDidResize($0)
                    }
            } else {
                RedZoneExpandedView(controller: controller)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                        controller.expandedDidResize($0)
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner.alignment)
    }
}

/// Drags the window by `NSEvent.mouseLocation`, and lets a click without movement fall
/// through to `onTap`. `isMovableByWindowBackground` would have swallowed the clicks.
struct RedZoneDrag: ViewModifier {
    let controller: RedZoneWindowController
    var onTap: (() -> Void)?

    func body(content: Content) -> some View {
        let drag = DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { _ in controller.dragChanged() }
            .onEnded { _ in controller.dragEnded() }
        if let onTap {
            content.gesture(drag.exclusively(before: TapGesture().onEnded { onTap() }))
        } else {
            content.gesture(drag)
        }
    }
}

// MARK: - Expanded

/// Everything on one small card with no spare room: the featured game in a few dense
/// lines (its score line doubles as the title bar), the last few moments from anywhere,
/// and every live score. Tapping any game features it; "Auto" hands the choice back.
struct RedZoneExpandedView: View {
    let controller: RedZoneWindowController

    @Environment(GameStore.self) private var store
    @Environment(RedZoneStore.self) private var redZone
    @Environment(FantasyStore.self) private var fantasy

    static let momentLimit = 5

    var body: some View {
        VStack(spacing: 0) {
            if let id = redZone.spotlightID, let game = store.game(id: id) {
                SpotlightCard(game: game, controls: controls)
                    .id(id)
                    .transition(.opacity)
            } else {
                HStack { Spacer(); controls }.padding(.horizontal, 6).frame(height: 18)
                    .modifier(RedZoneDrag(controller: controller))
            }
            if !redZone.moments.isEmpty {
                Divider().opacity(0.3)
                MomentList(moments: Array(redZone.moments.prefix(Self.momentLimit)),
                           onPick: pick, onOpen: open)
            }
            Divider().opacity(0.3)
            ScoreStrip(games: liveGames, featuredID: redZone.spotlightID,
                       pickedID: redZone.pickedID, onPick: pick, onOpen: open)
        }
        .animation(.snappy(duration: 0.2), value: redZone.spotlightID)
        .frame(width: RedZoneWindowController.expandedWidth)
        .glassCard(cornerRadius: 8)
    }

    /// Ordered by kickoff, not by rank, so the strip does not reshuffle every poll.
    private var liveGames: [Game] {
        store.games.filter(\.isLive).sorted {
            ($0.kickoff ?? .distantFuture, $0.id) < ($1.kickoff ?? .distantFuture, $1.id)
        }
    }

    /// Auto or back-to-auto, shrink, close — riding on the end of the score line.
    private var controls: RedZoneControls {
        RedZoneControls(controller: controller)
    }

    private func pick(_ gameID: String) {
        redZone.pick(gameID)
    }

    private func open(_ gameID: String) {
        PinnedGameWindowController.shared.show(gameID: gameID, store: store, fantasy: fantasy)
    }
}

struct RedZoneControls: View {
    let controller: RedZoneWindowController

    @Environment(RedZoneStore.self) private var redZone

    var body: some View {
        HStack(spacing: 6) {
            if redZone.isPicked {
                Button {
                    redZone.pick(nil)
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.uturn.backward")
                        Text("Auto")
                    }
                    .font(.system(size: 8, weight: .semibold))
                    .padding(.horizontal, 4)
                    .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .help("Go back to following the biggest moment")
            } else {
                Text("AUTO")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .help("Following the biggest moment in any game. Click a game to watch it instead.")
            }
            Button {
                controller.setMini(true)
            } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 7.5, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Shrink to a pill")
            Button {
                controller.close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 7.5, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Close RedZone")
        }
    }
}

// MARK: - Pill

struct RedZonePill: View {
    let controller: RedZoneWindowController

    @Environment(GameStore.self) private var store
    @Environment(RedZoneStore.self) private var redZone
    @State private var flash = false

    var body: some View {
        if let id = redZone.spotlightID, let game = store.game(id: id) {
            let inRedZone = game.situation?.isRedZone == true && game.teamWithPossession != nil
            HStack(spacing: 5) {
                if game.isLive {
                    LivePulse()
                } else {
                    Circle().fill(.secondary).frame(width: 6, height: 6)
                }
                if redZone.isPicked {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(.secondary)
                }
                Text(RedZoneText.pill(game))
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .padding(.horizontal, 7)
            .frame(height: RedZoneWindowController.pillHeight)
            .glassCard(tint: inRedZone ? .red : game.teamWithPossession?.tint,
                       interactive: true, cornerRadius: RedZoneWindowController.pillHeight / 2)
            .overlay(
                Capsule().stroke(Color.red, lineWidth: 1.5).opacity(flash ? 0.9 : 0)
            )
            .contentShape(Capsule())
            .modifier(RedZoneDrag(controller: controller, onTap: { controller.setMini(false) }))
            .help(redZone.spotlightReason)
            // A short flash when the spotlight moves or a score lands. Not a repeating
            // animation: those keep running in a window that outlives being shown.
            .onChange(of: id) { pulse() }
            .onChange(of: game.home.score + game.away.score) { pulse() }
        }
    }

    private func pulse() {
        withAnimation(.easeOut(duration: 0.15)) { flash = true }
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            withAnimation(.easeIn(duration: 0.4)) { flash = false }
        }
    }
}
