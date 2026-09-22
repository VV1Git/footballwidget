import SwiftUI
import AppKit
import FootballCore

extension Color {
    /// ESPN ships colors as bare hex with no `#`.
    init?(espnHex hex: String?) {
        guard var hex, !hex.isEmpty else { return nil }
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1
        )
    }

    var relativeLuminance: Double {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .black
        func channel(_ c: CGFloat) -> Double {
            let v = Double(c)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(ns.redComponent)
            + 0.7152 * channel(ns.greenComponent)
            + 0.0722 * channel(ns.blueComponent)
    }

    /// Team colors run from near-black (Ravens) to bright gold (Steelers). Nudge them
    /// toward the middle so they stay visible as ink on glass in either appearance.
    func legibleOnGlass(dark: Bool) -> Color {
        let luminance = relativeLuminance
        if dark && luminance < 0.16 { return blended(with: .white, amount: 0.55) }
        if !dark && luminance > 0.72 { return blended(with: .black, amount: 0.40) }
        return self
    }

    func blended(with other: Color, amount: Double) -> Color {
        let a = NSColor(self).usingColorSpace(.sRGB) ?? .black
        let b = NSColor(other).usingColorSpace(.sRGB) ?? .white
        let t = min(max(amount, 0), 1)
        return Color(
            .sRGB,
            red: Double(a.redComponent) * (1 - t) + Double(b.redComponent) * t,
            green: Double(a.greenComponent) * (1 - t) + Double(b.greenComponent) * t,
            blue: Double(a.blueComponent) * (1 - t) + Double(b.blueComponent) * t,
            opacity: 1
        )
    }
}

extension TeamSide {
    var tint: Color { Color(espnHex: primaryHex) ?? .accentColor }
    var altTint: Color { Color(espnHex: secondaryHex) ?? tint }

    /// `tint.legibleOnGlass(dark:)`, remembered per team colour.
    ///
    /// The adjustment round-trips through `NSColor` and a colour-space conversion —
    /// about 10µs a call measured, and the ladder asked for it twice per play row plus
    /// once per drive row, on every render. Team colours are fixed sRGB values, so the
    /// answer never changes; only the `.accentColor` fallback is dynamic, and that one
    /// is left uncached.
    @MainActor
    func legibleTint(dark: Bool) -> Color {
        guard let hex = primaryHex, let base = Color(espnHex: hex) else {
            return tint.legibleOnGlass(dark: dark)
        }
        let key = LegibleTintCache.Key(hex: hex, dark: dark)
        if let cached = LegibleTintCache.entries[key] { return cached }
        let adjusted = base.legibleOnGlass(dark: dark)
        LegibleTintCache.entries[key] = adjusted
        return adjusted
    }
}

@MainActor
private enum LegibleTintCache {
    struct Key: Hashable {
        let hex: String
        let dark: Bool
    }
    /// At most 32 teams × 2 appearances, so it is never trimmed.
    static var entries: [Key: Color] = [:]
}

/// Shared metrics so the panel and the torn-off window stay in step.
enum Metrics {
    static let panelWidth: CGFloat = 380
    static let panelMaxHeight: CGFloat = 560
    static let cornerRadius: CGFloat = 14
    static let rowSpacing: CGFloat = 8
    static let gutter: CGFloat = 12
}

/// Set to draw opaque chrome regardless of the system setting. `accessibilityReduce\
/// Transparency` is read-only, so offscreen rendering needs its own way in.
private struct OpaqueChromeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var forcesOpaqueChrome: Bool {
        get { self[OpaqueChromeKey.self] }
        set { self[OpaqueChromeKey.self] = newValue }
    }
}

/// Applies Liquid Glass, falling back to a plain material when the system asks for
/// reduced transparency.
struct GlassCard: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.forcesOpaqueChrome) private var forcesOpaqueChrome

    var tint: Color?
    var interactive: Bool = false
    var cornerRadius: CGFloat = Metrics.cornerRadius

    private var glass: Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparency || forcesOpaqueChrome {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(.separator, lineWidth: 0.5))
        } else {
            content.glassEffect(glass, in: shape)
        }
    }
}

extension View {
    func glassCard(tint: Color? = nil, interactive: Bool = false,
                   cornerRadius: CGFloat = Metrics.cornerRadius) -> some View {
        modifier(GlassCard(tint: tint, interactive: interactive, cornerRadius: cornerRadius))
    }
}
