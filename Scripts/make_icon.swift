#!/usr/bin/env swift
// Draws the app icon and writes an .iconset. Run via Scripts/make_icon.sh.
//
// The icon is what macOS puts on every notification banner, so it has to read at 32pt:
// a football on a field-green tile, no fine detail that would turn to mush.

import AppKit
import Foundation

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let context = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus(); return image
    }
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    let rect = CGRect(x: 0, y: 0, width: size, height: size)

    // Rounded tile, in the squircle proportion macOS uses.
    let radius = size * 0.2237
    let tile = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    context.saveGState()
    context.addPath(tile)
    context.clip()

    let colors = [
        NSColor(srgbRed: 0.11, green: 0.42, blue: 0.24, alpha: 1).cgColor,
        NSColor(srgbRed: 0.05, green: 0.24, blue: 0.14, alpha: 1).cgColor,
    ]
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: colors as CFArray, locations: [0, 1]) {
        context.drawLinearGradient(gradient,
                                   start: CGPoint(x: 0, y: size),
                                   end: CGPoint(x: 0, y: 0),
                                   options: [])
    }

    // Yard lines, so the tile reads as a field rather than a plain green square.
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.13).cgColor)
    context.setLineWidth(max(size * 0.012, 0.75))
    for step in 1..<6 {
        let x = size * CGFloat(step) / 6
        context.move(to: CGPoint(x: x, y: size * 0.06))
        context.addLine(to: CGPoint(x: x, y: size * 0.94))
    }
    context.strokePath()

    // Midfield line, a touch brighter.
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.22).cgColor)
    context.setLineWidth(max(size * 0.016, 1))
    context.move(to: CGPoint(x: size / 2, y: size * 0.06))
    context.addLine(to: CGPoint(x: size / 2, y: size * 0.94))
    context.strokePath()
    context.restoreGState()

    // The ball: a lens made from two arcs, tilted like a thrown spiral.
    context.saveGState()
    context.translateBy(x: size / 2, y: size / 2)
    context.rotate(by: -22 * .pi / 180)

    let ballWidth = size * 0.60
    let ballHeight = size * 0.375
    let ball = CGMutablePath()
    ball.move(to: CGPoint(x: -ballWidth / 2, y: 0))
    ball.addQuadCurve(to: CGPoint(x: ballWidth / 2, y: 0),
                      control: CGPoint(x: 0, y: ballHeight))
    ball.addQuadCurve(to: CGPoint(x: -ballWidth / 2, y: 0),
                      control: CGPoint(x: 0, y: -ballHeight))
    ball.closeSubpath()

    context.addPath(ball)
    context.setFillColor(NSColor(srgbRed: 0.52, green: 0.26, blue: 0.13, alpha: 1).cgColor)
    context.fillPath()

    context.addPath(ball)
    context.setStrokeColor(NSColor(srgbRed: 0.98, green: 0.97, blue: 0.95, alpha: 1).cgColor)
    context.setLineWidth(max(size * 0.022, 1))
    context.strokePath()

    // Laces.
    context.setStrokeColor(NSColor(srgbRed: 0.98, green: 0.97, blue: 0.95, alpha: 1).cgColor)
    context.setLineWidth(max(size * 0.028, 1))
    context.setLineCap(.round)
    context.move(to: CGPoint(x: -ballWidth * 0.17, y: 0))
    context.addLine(to: CGPoint(x: ballWidth * 0.17, y: 0))
    context.strokePath()

    context.setLineWidth(max(size * 0.020, 0.8))
    for i in -2...2 {
        let x = CGFloat(i) * ballWidth * 0.075
        context.move(to: CGPoint(x: x, y: -ballHeight * 0.135))
        context.addLine(to: CGPoint(x: x, y: ballHeight * 0.135))
    }
    context.strokePath()
    context.restoreGState()

    image.unlockFocus()
    return image
}

let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outputDirectory,
                                         withIntermediateDirectories: true)

let variants: [(name: String, size: CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    let image = drawIcon(size: variant.size)
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:])
    else { continue }
    let path = "\(outputDirectory)/\(variant.name).png"
    try? png.write(to: URL(fileURLWithPath: path))
}
print("wrote \(variants.count) images to \(outputDirectory)")
