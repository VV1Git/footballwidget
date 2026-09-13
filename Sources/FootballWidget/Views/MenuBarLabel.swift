import SwiftUI
import FootballCore

/// What sits in the menu bar: a football, plus whatever is worth knowing at a glance.
struct MenuBarLabel: View {
    @Environment(GameStore.self) private var store
    @Environment(Preferences.self) private var preferences
    @Environment(FantasyStore.self) private var fantasy

    /// SwiftUI does not observe the clock, so a countdown computed from `Date()` inside
    /// the body never re-renders and sits frozen at whatever it said first. Driving it
    /// from state that a timer updates is what makes it tick.
    @State private var now = Date()

    private let clock = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "football.fill")
                .opacity(store.liveCount > 0 ? 1 : 0.55)

            if store.liveCount > 0 {
                Text("\(store.liveCount)")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
            } else if let idle = idleText {
                Text(idle)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
            }
        }
        .onReceive(clock) { now = $0 }
    }

    /// Shown only when nothing is being played; a live game always wins the space.
    private var idleText: String? {
        switch preferences.idleBehavior {
        case .countdown:
            guard let next = store.nextKickoff else { return nil }
            return Countdown.text(until: next, from: now)
        case .fantasyScore:
            return fantasy.matchup?.compactScore
        case .showSchedule, .hideIcon:
            return nil
        }
    }
}
