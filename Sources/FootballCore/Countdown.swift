import Foundation

/// Formats "time until kickoff" for the menu bar.
///
/// Pure so it can be tested, and because the view has to pass in `now` explicitly —
/// reading `Date()` inside a SwiftUI body means nothing observes the clock and the
/// label never re-renders, which is exactly how the countdown came to sit frozen.
public enum Countdown {

    /// "2d", "3:05", "45m", "1m". Nil once the kickoff has passed.
    public static func text(until kickoff: Date, from now: Date = .now) -> String? {
        let remaining = kickoff.timeIntervalSince(now)
        guard remaining > 0 else { return nil }

        let totalMinutes = Int((remaining / 60).rounded(.up))
        let days = totalMinutes / (60 * 24)
        if days >= 1 { return "\(days)d" }

        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 { return "\(hours):" + String(format: "%02d", minutes) }
        return "\(max(totalMinutes, 1))m"
    }

    /// How long until the displayed text would change, so the view can tick no more
    /// often than it needs to.
    public static func secondsUntilTextChanges(until kickoff: Date, from now: Date = .now) -> TimeInterval {
        let remaining = kickoff.timeIntervalSince(now)
        guard remaining > 0 else { return 60 }
        let intoMinute = remaining.truncatingRemainder(dividingBy: 60)
        return intoMinute > 0 ? intoMinute : 60
    }
}
