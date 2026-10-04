import AppKit
import SwiftUI
import FootballCore

/// The RedZone window: a featured game, the moments from every game, and a strip of
/// scores — or, folded up, a one-line pill in a corner of the screen.
///
/// It floats above everything on every Space without ever taking focus, sits snapped to
/// a corner, and is only on screen while there is football being played. "Open" is the
/// user's choice and survives relaunch; whether it is showing follows the slate.
@MainActor
final class RedZoneWindowController: NSObject, NSWindowDelegate {
    static let shared = RedZoneWindowController()

    private var panel: NSPanel?
    private weak var store: GameStore?
    private weak var redZone: RedZoneStore?
    private weak var fantasy: FantasyStore?
    private let preferences = Preferences.shared
    private var screenObserver: NSObjectProtocol?
    /// Where the window and the mouse were when a drag began. The window moves under the
    /// gesture, so offsets are measured in screen coordinates rather than the view's.
    private var dragStart: (origin: CGPoint, mouse: CGPoint)?
    /// The pill's width, kept to 16 pt steps so a ticking clock does not resize it.
    private var pillSize = CGSize(width: 240, height: RedZoneWindowController.pillHeight)
    /// The full view's height follows its content — a few moments early in the
    /// afternoon, eight once it is busy — so it never holds screen it is not using.
    private var expandedHeight: CGFloat = 160

    static let pillHeight: CGFloat = 22
    static let expandedWidth: CGFloat = 300
    /// The tallest the full view gets, with every moment row filled.
    static let expandedSize = CGSize(width: expandedWidth, height: 220)

    var isOpen: Bool { preferences.redZoneOpen }

    /// Starts following the slate. Called once at launch; shows the window as soon as
    /// it is open and a game is live.
    func attach(store: GameStore, redZone: RedZoneStore, fantasy: FantasyStore) {
        self.store = store
        self.redZone = redZone
        self.fantasy = fantasy
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.place(animated: false) }
            }
        }
        observe()
        update()
    }

    func toggle() { preferences.redZoneOpen.toggle() }

    /// The close button. Quitting the app never calls this, so an open window comes back
    /// on the next launch.
    func close() { preferences.redZoneOpen = false }

    func setMini(_ mini: Bool) {
        preferences.redZoneMini = mini
        place(animated: true)
        updateFocus()
    }

    // MARK: - Showing and hiding

    /// Re-armed after every change: the window follows whether it is open, whether there
    /// is a game to feature, and which size it is.
    private func observe() {
        withObservationTracking {
            _ = preferences.redZoneOpen
            _ = preferences.redZoneMini
            _ = redZone?.spotlightID
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observe()
                self?.update()
            }
        }
    }

    private func update() {
        let shouldShow = preferences.redZoneOpen && redZone?.spotlightID != nil
        if shouldShow {
            show()
        } else {
            hide()
        }
    }

    private func show() {
        guard let store, let redZone, let fantasy else { return }
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: Self.expandedSize),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.isReleasedWhenClosed = false
            panel.isMovable = false
            panel.delegate = self

            let root = RedZoneRootView(controller: self)
                .environment(store)
                .environment(fantasy)
                .environment(redZone)
                .environment(preferences)
            let hosting = ClickThroughHostingView(rootView: root)
            // The window's frame is set from the corner and the mode; SwiftUI must not
            // resize it to its content and fight the anchoring.
            hosting.sizingOptions = []
            panel.contentView = hosting
            self.panel = panel
            place(animated: false)
        }
        panel?.orderFrontRegardless()
        updateFocus()
    }

    /// Dropped entirely rather than ordered out: a hidden hosting view still re-renders
    /// on every poll.
    private func hide() {
        guard let panel else {
            store?.setFocus(nil, for: .redZone)
            return
        }
        panel.orderOut(nil)
        panel.contentView = nil
        self.panel = nil
        store?.setFocus(nil, for: .redZone)
    }

    /// The scoreboard is all RedZone reads, so it asks for no play feeds — just a
    /// faster scoreboard while it is up: every five seconds expanded, ten as a pill.
    private func updateFocus() {
        guard panel != nil else { return }
        store?.setFocus(preferences.redZoneMini ? .list : .ticker, for: .redZone)
    }

    // MARK: - Placement

    private var corner: ScreenCorner {
        ScreenCorner(rawValue: preferences.redZoneCorner) ?? .bottomRight
    }

    private var size: CGSize {
        preferences.redZoneMini ? pillSize : CGSize(width: Self.expandedWidth, height: expandedHeight)
    }

    /// The saved display if it is still attached, otherwise the main one.
    private var screen: NSScreen? {
        let saved = preferences.redZoneDisplayID
        return NSScreen.screens.first { $0.displayID == saved } ?? NSScreen.main ?? NSScreen.screens.first
    }

    func place(animated: Bool) {
        guard let panel, let screen else { return }
        let frame = CornerLayout.frame(size: size, corner: corner, in: screen.visibleFrame)
        panel.setFrame(frame, display: true, animate: animated)
        panel.invalidateShadow()
    }

    /// The pill reports its natural size; the window follows it in 16 pt steps.
    func pillDidResize(_ natural: CGSize) {
        let width = min(400, max(140, (natural.width / 16).rounded(.up) * 16))
        let next = CGSize(width: width, height: Self.pillHeight)
        guard next != pillSize else { return }
        pillSize = next
        if preferences.redZoneMini { place(animated: false) }
    }

    /// The full view reports its natural height; the window grows away from its corner.
    func expandedDidResize(_ natural: CGFloat) {
        let height = min(400, max(40, natural.rounded(.up)))
        guard height != expandedHeight else { return }
        expandedHeight = height
        if !preferences.redZoneMini { place(animated: true) }
    }

    // MARK: - Dragging

    func dragChanged() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        if dragStart == nil { dragStart = (panel.frame.origin, mouse) }
        guard let start = dragStart else { return }
        panel.setFrameOrigin(CGPoint(x: start.origin.x + mouse.x - start.mouse.x,
                                     y: start.origin.y + mouse.y - start.mouse.y))
    }

    /// Lets go into the nearest corner of whichever screen the window is mostly on.
    func dragEnded() {
        dragStart = nil
        guard let panel else { return }
        let center = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        let target = NSScreen.screens.first { $0.frame.contains(center) } ?? panel.screen ?? NSScreen.main
        guard let target else { return }
        preferences.redZoneCorner = CornerLayout.nearest(to: center, in: target.visibleFrame).rawValue
        preferences.redZoneDisplayID = target.displayID
        place(animated: true)
    }

    // MARK: - NSWindowDelegate

    func windowDidChangeScreen(_ notification: Notification) {
        guard dragStart == nil else { return }
        place(animated: false)
    }
}

private extension NSScreen {
    var displayID: Int {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0
    }
}

extension ScreenCorner {
    /// Content hugs the corner the window is anchored to, so it stays put while the
    /// window animates between sizes.
    var alignment: Alignment {
        switch self {
        case .topLeft: return .topLeading
        case .topRight: return .topTrailing
        case .bottomLeft: return .bottomLeading
        case .bottomRight: return .bottomTrailing
        }
    }
}
