import CoreGraphics
import Foundation
import Testing
@testable import FootballCore

private let laptop = CGRect(x: 0, y: 0, width: 1440, height: 875)

private func inside(_ frame: CGRect, _ visible: CGRect) -> Bool {
    visible.contains(frame)
}

/// AppKit's y goes up, so "top" is the larger y.
@Test func cornerNearestPicksTheQuadrant() {
    #expect(CornerLayout.nearest(to: CGPoint(x: 100, y: 800), in: laptop) == .topLeft)
    #expect(CornerLayout.nearest(to: CGPoint(x: 1300, y: 800), in: laptop) == .topRight)
    #expect(CornerLayout.nearest(to: CGPoint(x: 100, y: 50), in: laptop) == .bottomLeft)
    #expect(CornerLayout.nearest(to: CGPoint(x: 1300, y: 50), in: laptop) == .bottomRight)
}

@Test func cornerFrameIsAnchoredInsetFromBothEdges() {
    let size = CGSize(width: 208, height: 28)
    #expect(CornerLayout.frame(size: size, corner: .bottomRight, in: laptop)
            == CGRect(x: 1220, y: 12, width: 208, height: 28))
    #expect(CornerLayout.frame(size: size, corner: .topLeft, in: laptop)
            == CGRect(x: 12, y: 835, width: 208, height: 28))
    #expect(CornerLayout.frame(size: size, corner: .topRight, in: laptop, inset: 0)
            == CGRect(x: 1232, y: 847, width: 208, height: 28))
}

/// A window wider than the screen less its insets gives the inset up; one bigger than
/// the screen is cut down to it.
@Test func cornerFrameStaysOnScreen() {
    let small = CGRect(x: 0, y: 0, width: 300, height: 400)
    let wide = CornerLayout.frame(size: CGSize(width: 290, height: 460), corner: .bottomLeft, in: small)
    #expect(wide == CGRect(x: 10, y: 0, width: 290, height: 400))
    for corner in ScreenCorner.allCases {
        #expect(inside(CornerLayout.frame(size: CGSize(width: 340, height: 460), corner: corner, in: small), small))
    }
}

/// A display to the left of and below the main one has negative coordinates.
@Test func cornerLayoutWorksOnANegativeOriginScreen() {
    let secondary = CGRect(x: -1920, y: -200, width: 1920, height: 1055)
    #expect(CornerLayout.nearest(to: CGPoint(x: -100, y: 800), in: secondary) == .topRight)
    #expect(CornerLayout.nearest(to: CGPoint(x: -1800, y: -150), in: secondary) == .bottomLeft)

    let size = CGSize(width: 340, height: 460)
    #expect(CornerLayout.frame(size: size, corner: .topLeft, in: secondary)
            == CGRect(x: -1908, y: 383, width: 340, height: 460))
    #expect(CornerLayout.frame(size: size, corner: .bottomRight, in: secondary)
            == CGRect(x: -352, y: -188, width: 340, height: 460))
    for corner in ScreenCorner.allCases {
        #expect(inside(CornerLayout.frame(size: size, corner: corner, in: secondary), secondary))
    }
}

/// Stored in preferences by raw value.
@Test func cornerRawValuesAreStable() {
    #expect(ScreenCorner.allCases.map(\.rawValue) == ["topLeft", "topRight", "bottomLeft", "bottomRight"])
    #expect(ScreenCorner(rawValue: "bottomRight") == .bottomRight)
}
