import SwiftUI
import AppKit
import FootballCore

/// Tears a game out of the panel into a small floating window that stays above other
/// apps, so it can sit beside a stream while the menu bar panel is closed.
@MainActor
final class PinnedGameWindowController {
    static let shared = PinnedGameWindowController()

    private var windows: [String: NSPanel] = [:]

    func show(gameID: String, store: GameStore, fantasy: FantasyStore) {
        if let existing = windows[gameID] {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let content = PinnedGameView(gameID: gameID)
        .environment(store)
        .environment(fantasy)
        .environment(Preferences.shared)

        // A non-activating panel keeps focus in whatever you are watching.
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = store.game(id: gameID)?.shortName ?? "Game"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        // Dragging by the background turns every click into a potential window drag,
        // and AppKit swallows the mouse-down before SwiftUI sees it — which made the
        // play rows unclickable. The title bar area is still there to drag by.
        panel.isMovableByWindowBackground = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentView = ClickThroughHostingView(rootView: content)
        // Autosaved per game, so a window you sized once comes back that way.
        panel.setFrameAutosaveName("pinned-game")
        // Small enough to tuck into a corner. The detail view drops down to a bare
        // scoreline at this size rather than squashing everything.
        panel.minSize = NSSize(width: 170, height: 64)
        panel.maxSize = NSSize(width: 900, height: 1200)

        if panel.frame.origin == .zero { panel.center() }
        panel.orderFrontRegardless()

        windows[gameID] = panel
        store.focus = .detail(gameID: gameID)
        Task { await store.refreshDetail(id: gameID) }
    }

    func close(gameID: String) {
        windows[gameID]?.close()
        windows[gameID] = nil
    }

    var hasPinnedGames: Bool { !windows.isEmpty }
    var pinnedGameIDs: [String] { Array(windows.keys) }
}

/// A hosting view that answers clicks even though its window never becomes key.
///
/// The pinned window is a `.nonactivatingPanel`, which is what keeps it from stealing
/// focus from whatever you are watching. The cost is that AppKit treats every click on
/// it as a click on a non-key window and, by default, throws it away rather than
/// delivering it — so the play rows could not be opened at all. Accepting first mouse
/// is the opt-in that says "deliver it anyway".
private final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Contents of a torn-off window.
private struct PinnedGameView: View {
    let gameID: String

    @Environment(GameStore.self) private var store

    var body: some View {
        Group {
            if let game = store.game(id: gameID) {
                GameDetailView(game: game, detail: store.detail(id: gameID))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 170, minHeight: 64)
        .background(.ultraThinMaterial)
        .task(id: gameID) {
            // The window can outlive the panel, so it keeps its own game fed.
            while !Task.isCancelled {
                await store.refreshDetail(id: gameID)
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}
