import SwiftUI
import AppKit
import FootballCore

/// Captures the real panel to a PNG without ever putting a window on screen.
///
/// `ImageRenderer` cannot lay out `ScrollView` content, which is most of the panel, so
/// this hosts the view in an ordinary `NSWindow` that is never ordered front and reads
/// the bitmap straight off the view. That gives a true picture of what clicking the
/// menu bar icon shows.
@MainActor
enum PanelCapture {

    /// Renders any view offscreen the same way, for checking settings panes.
    static func captureView(_ view: some View, to path: String, size: CGSize) -> String? {
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]),
              (try? png.write(to: URL(fileURLWithPath: path))) != nil else { return nil }
        return path
    }

    /// `forcedHeight: nil` lets the view size itself, which is what `MenuBarExtra`'s
    /// window does. Passing a height instead only proves the view *can* lay out, not
    /// that it does when the window is sizing to content.
    static func capture(
        store: GameStore,
        fantasy: FantasyStore,
        to path: String,
        width: CGFloat = Metrics.panelWidth,
        forcedHeight: CGFloat? = nil
    ) -> String? {
        let base = PanelRootView()
            .environment(store)
            .environment(fantasy)
            .environment(Preferences.shared)
            .background(Color(nsColor: .windowBackgroundColor))

        let content: AnyView = forcedHeight.map {
            AnyView(base.frame(width: width, height: $0))
        } ?? AnyView(base.frame(width: width))

        let hosting = NSHostingView(rootView: content)
        // This is how a self-sizing AppKit host (a MenuBarExtra window, for one) asks
        // SwiftUI how big to be. A view whose scrollable region has no definite height
        // reports a collapsed intrinsic height here even though `fittingSize` looks fine.
        hosting.sizingOptions = [.intrinsicContentSize]
        let intrinsic = hosting.intrinsicContentSize
        print("  intrinsicContentSize: \(intrinsic)")
        let fitted = hosting.fittingSize
        let size = CGSize(width: width,
                          height: forcedHeight ?? max(fitted.height, 1))
        hosting.frame = NSRect(origin: .zero, size: size)
        print("  panel fitting size: \(fitted) -> using \(size)")

        // A real window is needed for layout, but it is never ordered front, so nothing
        // appears on the user's display.
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.isReleasedWhenClosed = false

        hosting.layoutSubtreeIfNeeded()
        // Let SwiftUI settle: images, lazy stacks and scroll content resolve on the
        // run loop rather than synchronously.
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        hosting.layoutSubtreeIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            return nil
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]),
              (try? png.write(to: URL(fileURLWithPath: path))) != nil
        else { return nil }
        return path
    }
}
