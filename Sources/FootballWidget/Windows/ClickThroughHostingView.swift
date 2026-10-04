import SwiftUI
import AppKit

/// A hosting view that answers clicks even though its window never becomes key.
///
/// The floating windows are `.nonactivatingPanel`s, which is what keeps them from
/// stealing focus from whatever you are watching. The cost is that AppKit treats every
/// click on one as a click on a non-key window and, by default, throws it away rather
/// than delivering it — so the pinned window's play rows could not be opened at all.
/// Accepting first mouse is the opt-in that says "deliver it anyway".
final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
