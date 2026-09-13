import SwiftUI
import AppKit

/// Opens the panel in an ordinary window.
///
/// The menu bar panel cannot be opened programmatically, which makes it awkward to
/// look at while building. `FootballWidget --preview` renders the same view in a
/// window instead. Pair it with `--replay` to see a live game without waiting for one.
@MainActor
enum PreviewWindowController {
    private static var window: NSWindow?

    static var isRequested: Bool { CommandLine.arguments.contains("--preview") }

    static func show(store: GameStore, fantasy: FantasyStore, preferences: Preferences) {
        guard window == nil else {
            window?.makeKeyAndOrderFront(nil)
            return
        }
        let content = PanelRootView()
            .environment(store)
            .environment(fantasy)
            .environment(preferences)
            .frame(width: Metrics.panelWidth)
            .frame(minHeight: 300, maxHeight: Metrics.panelMaxHeight)
            .background(.ultraThinMaterial)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.panelWidth, height: 560),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Football — preview"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content)
        window.center()
        window.orderFront(nil)
        Self.window = window
    }
}
