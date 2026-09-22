import SwiftUI
import AppKit
import ImageIO
import FootballCore

/// One game in the panel list: both teams, the score, and — while live — who has the
/// ball, where it is and how long is left.
struct GameRowView: View {
    let game: Game
    let onSelect: () -> Void
    /// Called with the abbreviation of the specific team that was starred.
    let onToggleFavorite: (String) -> Void

    @Environment(Preferences.self) private var preferences

    @Environment(\.colorScheme) private var scheme
    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .center, spacing: 10) {
                VStack(spacing: 4) {
                    teamLine(game.away)
                    teamLine(game.home)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 3) {
                    statusColumn
                    FantasyBadge(game: game).equatable()
                }
                .frame(width: 96, alignment: .trailing)

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(isHovering ? 1 : 0.35)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassCard(tint: cardTint, interactive: true)
        .onHover { isHovering = $0 }
    }

    // MARK: - Teams

    private func teamLine(_ team: TeamSide) -> some View {
        HStack(spacing: 6) {
            favoriteStar(team)

            TeamLogo(url: team.logoURL, fallbackTint: team.tint)
                .frame(width: 17, height: 17)

            Text(team.abbreviation)
                .font(.system(size: 12, weight: isLosing(team) ? .regular : .semibold))
                .foregroundStyle(isLosing(team) ? .secondary : .primary)

            if hasPossession(team) {
                Image(systemName: "football.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(team.legibleTint(dark: scheme == .dark))
                    .transition(.scale.combined(with: .opacity))
            }

            if game.phase == .pre, let record = team.record {
                Text(record)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 4)

            if game.phase != .pre {
                Text("\(team.score)")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isLosing(team) ? .secondary : .primary)
            }
        }
    }

    private func hasPossession(_ team: TeamSide) -> Bool {
        game.isLive && game.situation?.possessionTeamID == team.id
    }

    /// Dim the trailing team so the scoreline reads at a glance.
    private func isLosing(_ team: TeamSide) -> Bool {
        guard game.phase != .pre else { return false }
        let other = team.id == game.home.id ? game.away : game.home
        return team.score < other.score
    }

    // MARK: - Status

    @ViewBuilder
    private var statusColumn: some View {
        VStack(alignment: .trailing, spacing: 2) {
            switch game.phase {
            case .pre:
                Text(kickoffText)
                    .font(.system(size: 11, weight: isToday ? .semibold : .medium))
                    .foregroundStyle(isToday ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                if let broadcast = game.broadcast {
                    Text(broadcast)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }

            case .final:
                Text(game.period > 4 ? "Final/OT" : "Final")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

            case .halftime:
                Text("Halftime")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

            case .live, .unknown:
                HStack(spacing: 4) {
                    LivePulse()
                    Text("\(game.periodLabel) \(game.displayClock)")
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                }
                if let situation = game.situation {
                    Text(situation.shortDownDistance ?? situation.downDistanceText ?? "")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let spot = situation.possessionText, !spot.isEmpty {
                        Text(spot)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(situation.isRedZone ? AnyShapeStyle(Color.red) : AnyShapeStyle(.tertiary))
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    /// Formatters are built once. A fresh `DateFormatter` per render costs ~70µs
    /// against ~2µs to reuse one, and every upcoming game asked for one each time the
    /// list redrew.
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    private static let dayTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "E h:mm a"
        return formatter
    }()

    private var kickoffText: String {
        guard let kickoff = game.kickoff else { return game.statusDetail }
        let calendar = Calendar.current
        if calendar.isDateInToday(kickoff) {
            // Spelling out "Today" beats leaving it implicit in a list that spans the
            // whole week — a bare time reads like just another Sunday game.
            return "Today \(Self.timeFormatter.string(from: kickoff))"
        }
        if calendar.isDateInTomorrow(kickoff) {
            return "Tomorrow \(Self.timeFormatter.string(from: kickoff))"
        }
        return Self.dayTimeFormatter.string(from: kickoff)
    }

    private var isToday: Bool {
        guard let kickoff = game.kickoff else { return false }
        return Calendar.current.isDateInToday(kickoff)
    }

    // MARK: - Chrome

    private var cardTint: Color? {
        guard game.isLive else { return nil }
        if game.situation?.isRedZone == true { return .red }
        return game.teamWithPossession?.tint
    }

    /// Sits in a fixed-width slot so showing it on hover never shifts the row.
    private func favoriteStar(_ team: TeamSide) -> some View {
        let isOn = preferences.isFavorite(team.abbreviation)
        return Button {
            onToggleFavorite(team.abbreviation)
        } label: {
            Image(systemName: isOn ? "star.fill" : "star")
                .font(.system(size: 8))
                .foregroundStyle(isOn ? AnyShapeStyle(Color.yellow) : AnyShapeStyle(.tertiary))
        }
        .buttonStyle(.plain)
        .frame(width: 9)
        .opacity(isOn ? 1 : (isHovering ? 0.7 : 0))
        .help(isOn ? "Unfavorite \(team.displayName)" : "Favorite \(team.displayName)")
    }
}

/// How many of your starters are playing in this game.
///
/// Its own view because it is the only part of the row that reads the fantasy store,
/// whose matchups change on almost every fifteen-second poll while games are live.
/// Inside the row, each of those polls re-ran every game card's body; out here it
/// re-runs a badge.
private struct FantasyBadge: View {
    let game: Game

    @Environment(FantasyStore.self) private var fantasy

    var body: some View {
        let count = fantasy.myPlayerCount(inGame: game)
        if count > 0 {
            HStack(spacing: 2) {
                Image(systemName: "person.fill")
                    .font(.system(size: 6))
                Text("\(count)")
                    .font(.system(size: 8, weight: .bold))
                    .monospacedDigit()
            }
            .foregroundStyle(Color.green)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.green.opacity(0.15)))
            .help("\(count) of your starters \(count == 1 ? "is" : "are") in this game")
        }
    }
}

extension FantasyBadge: Equatable {
    /// The count depends only on which two teams are playing.
    nonisolated static func == (lhs: FantasyBadge, rhs: FantasyBadge) -> Bool {
        lhs.game.home.id == rhs.game.home.id && lhs.game.away.id == rhs.game.away.id
    }
}

/// A quiet breathing dot, so "live" reads without shouting.
///
/// The breathing is a Core Animation animation rather than a SwiftUI one. A SwiftUI
/// `repeatForever` is driven frame by frame on the main thread — about a millisecond of
/// main-thread work per frame for twelve of them in glass cards, measured — and there
/// is one in every live row, the section header, the detail header, the current drive
/// and the matchup. The menu bar panel's window outlives its closing, and in a test
/// window that was never put on screen SwiftUI animated regardless, so these most
/// likely kept running with the panel shut. Core Animation runs the same curve
/// (ease-in-out, 1.1s each way, 0.35 ↔ 1 opacity) in the render server, and not at all
/// for a window off screen.
struct LivePulse: View {
    @Environment(\.forcesOpaqueChrome) private var forcesOpaqueChrome

    var body: some View {
        if forcesOpaqueChrome {
            // Offscreen rendering (`ImageRenderer`, `cacheDisplay`) cannot draw an
            // AppKit view's layers, and has no clock to animate against anyway.
            Circle()
                .fill(.red)
                .frame(width: 5, height: 5)
        } else {
            PulsingDot()
                .frame(width: 5, height: 5)
        }
    }
}

private struct PulsingDot: NSViewRepresentable {
    func makeNSView(context: Context) -> PulsingDotView { PulsingDotView() }
    func updateNSView(_ view: PulsingDotView, context: Context) { view.startPulsing() }
}

/// The dot is a sublayer this view owns, and the animation runs on that sublayer. The
/// view's own layer is left to AppKit and SwiftUI, so an opacity they apply to it — a
/// fading transition, say — still multiplies with the pulse instead of being
/// overridden by it.
private final class PulsingDotView: NSView {
    private static let animationKey = "livePulse"
    private let dot = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(dot)
        updateColor()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 5, height: 5) }

    /// Clicks belong to the row or header underneath, not to the dot.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.frame = bounds
        dot.path = CGPath(ellipseIn: bounds, transform: nil)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColor()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        dot.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        dot.contentsScale = window?.backingScaleFactor ?? 2
        startPulsing()
    }

    /// `Color.red` in SwiftUI is the system red, which shifts slightly between light and
    /// dark; resolving it against this view's appearance keeps the two the same.
    private func updateColor() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            dot.fillColor = NSColor.systemRed.cgColor
        }
        CATransaction.commit()
    }

    func startPulsing() {
        // Animations can be stripped when a view leaves its window, so this is checked
        // again whenever the view is attached or updated.
        guard window != nil, dot.animation(forKey: Self.animationKey) == nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.35
        pulse.toValue = 1.0
        pulse.duration = 1.1
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        // SwiftUI's `.easeInOut` is the same (0.42, 0, 0.58, 1) curve.
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pulse.isRemovedOnCompletion = false
        dot.add(pulse, forKey: Self.animationKey)
    }
}

/// Team logo with a coloured dot as a stand-in while it loads or if it fails.
///
/// `AsyncImage` kept no memory cache, so each time the list was rebuilt — coming back
/// from a game, say — all 32 logos were fetched again and each 500×500 PNG decoded
/// again (~3ms apiece measured) to be drawn at 17pt, flashing the placeholder dots in
/// the meantime. `LogoCache` decodes each logo once, off the main thread, at a size
/// still well above anything it is drawn at.
struct TeamLogo: View {
    let url: URL?
    let fallbackTint: Color

    private struct Loaded {
        let url: URL
        let image: CGImage
    }

    @State private var loaded: Loaded?

    var body: some View {
        let image = (loaded?.url == url ? loaded?.image : nil)
            ?? url.flatMap { LogoCache.shared.image(for: $0) }

        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Circle().fill(fallbackTint.opacity(0.55))
            }
        }
        .task(id: url) {
            guard let url, LogoCache.shared.image(for: url) == nil else { return }
            if let image = await LogoCache.shared.load(url) {
                loaded = Loaded(url: url, image: image)
            }
        }
    }
}

/// Team logos, decoded once per launch and shared by every view that shows one.
@MainActor
final class LogoCache {
    static let shared = LogoCache()

    /// The largest logo is drawn at 24pt, so 128px leaves room for a 2x display and
    /// then some, at ~65KB each rather than the ~1MB of a full 500px decode.
    nonisolated private static let maxPixelSize = 128

    private var images: [URL: CGImage] = [:]
    private var pending: [URL: Task<CGImage?, Never>] = [:]

    func image(for url: URL) -> CGImage? { images[url] }

    /// Loads through the shared URL session (and so its disk cache, as `AsyncImage`
    /// did). Concurrent requests for the same logo share one download. Failures are not
    /// remembered, so a logo that could not load is tried again next time it is shown.
    func load(_ url: URL) async -> CGImage? {
        if let image = images[url] { return image }
        if let task = pending[url] { return await task.value }

        let task = Task.detached(priority: .utility) { () -> CGImage? in
            guard let (data, response) = try? await URLSession.shared.data(from: url) else { return nil }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
            return Self.downsample(data)
        }
        pending[url] = task
        let image = await task.value
        pending[url] = nil
        if let image { images[url] = image }
        return image
    }

    nonisolated private static func downsample(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            // Decode now, on this background thread, rather than lazily at first draw
            // on the main thread.
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
