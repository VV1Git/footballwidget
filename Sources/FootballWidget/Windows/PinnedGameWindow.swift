import SwiftUI
import AppKit
import FootballCore

/// Tears a game out of the panel into a small floating window that stays above other
/// apps, so it can sit beside a stream while the menu bar panel is closed.
@MainActor
final class PinnedGameWindowController: NSObject, NSWindowDelegate {
    static let shared = PinnedGameWindowController()

    private var windows: [String: NSPanel] = [:]
    private weak var store: GameStore?

    func show(gameID: String, store: GameStore, fantasy: FantasyStore) {
        if let existing = windows[gameID] {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        self.store = store

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
        panel.delegate = self
        panel.contentView = ClickThroughHostingView(rootView: content)
        // One name shared by every pinned window, so a new one opens at the size you last
        // left one. AppKit lets only one open window hold a name, so a second window
        // pinned at the same time does not save its frame.
        panel.setFrameAutosaveName("pinned-game")
        // Small enough to tuck into a corner. The detail view drops down to a bare
        // scoreline at this size rather than squashing everything.
        panel.minSize = NSSize(width: 170, height: 64)
        panel.maxSize = NSSize(width: 900, height: 1200)

        if panel.frame.origin == .zero { panel.center() }
        panel.orderFrontRegardless()

        windows[gameID] = panel
        store.setFocus(.detail(gameID: gameID), for: .pinned(gameID))
        Task { await store.refreshDetail(id: gameID) }
    }

    /// The rest happens in `windowWillClose`, which the close button goes through too.
    func close(gameID: String) {
        windows[gameID]?.close()
    }

    /// A closed panel is not released (`isReleasedWhenClosed` is off), and its hosting
    /// view went with it: the game kept its focus, and the view its five-second refresh
    /// loop, behind a window nobody could see. Dropping the content ends the loop.
    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel,
              let id = windows.first(where: { $0.value === panel })?.key
        else { return }
        windows[id] = nil
        store?.setFocus(nil, for: .pinned(id))
        panel.contentView = nil
    }

    var hasPinnedGames: Bool { !windows.isEmpty }
    var pinnedGameIDs: [String] { Array(windows.keys) }
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
            // The window can outlive the panel, so it keeps its own game fed. When the
            // store's own loop is already polling this game (focus is on it), the two
            // overlap; `refreshDetail` shares a fetch made in the last few seconds
            // rather than pulling the same feed twice.
            while !Task.isCancelled {
                await store.refreshDetail(id: gameID)
                // A finished game's feed has stopped moving, so after one fetch past the
                // whistle it is neither polled here nor kept in focus. Same for a game
                // gone from the slate.
                guard let game = store.game(id: gameID), game.phase != .final else {
                    store.setFocus(nil, for: .pinned(gameID))
                    return
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}
