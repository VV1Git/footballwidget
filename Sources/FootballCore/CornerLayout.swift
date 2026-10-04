import CoreGraphics
import Foundation

/// Where the RedZone window sits. Stored by raw value, so the cases must keep their names.
public enum ScreenCorner: String, CaseIterable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight

    var isTop: Bool { self == .topLeft || self == .topRight }
    var isLeft: Bool { self == .topLeft || self == .bottomLeft }
}

/// Window placement in AppKit's coordinates: origin at the bottom left, y going up. A
/// screen to the left of or below the main one has negative coordinates, so nothing
/// here assumes the visible frame starts at zero.
public enum CornerLayout {

    /// The corner whose quadrant holds `point` — where a dragged window should snap to.
    public static func nearest(to point: CGPoint, in visible: CGRect) -> ScreenCorner {
        let top = point.y >= visible.midY
        let left = point.x < visible.midX
        switch (top, left) {
        case (true, true): return .topLeft
        case (true, false): return .topRight
        case (false, true): return .bottomLeft
        case (false, false): return .bottomRight
        }
    }

    /// A window of `size` tucked into `corner`, `inset` points from both edges. Never
    /// leaves the visible frame: a window too big for the inset gives the inset up, and
    /// one bigger than the screen is cut down to it.
    public static func frame(size: CGSize, corner: ScreenCorner, in visible: CGRect,
                             inset: CGFloat = 12) -> CGRect {
        let width = min(size.width, visible.width)
        let height = min(size.height, visible.height)
        let x = corner.isLeft ? visible.minX + inset : visible.maxX - inset - width
        let y = corner.isTop ? visible.maxY - inset - height : visible.minY + inset
        return CGRect(
            x: min(max(x, visible.minX), visible.maxX - width),
            y: min(max(y, visible.minY), visible.maxY - height),
            width: width,
            height: height
        )
    }
}
