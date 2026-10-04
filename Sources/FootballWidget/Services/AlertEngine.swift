import Foundation
import UserNotifications
import FootballCore

/// Delivers the notifications that `AlertRules` decides on.
///
/// This type holds only the plumbing — remembering what each game looked like last
/// poll, de-duplicating, and talking to the notification centre. The rules themselves
/// live in `FootballCore.AlertRules` where they can be tested without posting anything.
actor AlertEngine {
    private var snapshots: [String: GameSnapshot] = [:]
    /// Shared by the NFL and fantasy alerts, and bounded rather than emptied wholesale.
    private var delivered = DeliveredLog()
    private var askedForAuthorization = false
    /// When the scoreboard was last known to be current, changed or not.
    private var lastScoreboard: Date?

    /// Live polls are at most twenty seconds apart. After a longer gap — the Mac asleep,
    /// the network down — the snapshots describe the game as it was minutes ago, and
    /// comparing against them announced a quarter of football as one "SEA +14".
    static let maximumScoreboardGap: TimeInterval = 150

    /// `muted`: work the events out and log them as delivered, but post nothing. RedZone
    /// on screen is already showing them, and logging them means none fires late once
    /// it closes.
    func process(previous: [Game], current: [Game], preferences: Preferences, muted: Bool = false) async {
        let settings = await MainActor.run { preferences.alertSettings }

        let now = Date.now
        if let lastScoreboard, now.timeIntervalSince(lastScoreboard) > Self.maximumScoreboardGap {
            // Every game is seen afresh: nothing fires, and the next poll compares
            // against now.
            snapshots = [:]
        }
        lastScoreboard = now

        for game in current {
            let events = AlertRules.events(
                previous: snapshots[game.id],
                game: game,
                settings: settings
            )
            // Built from the last snapshot so it remembers which play has already been
            // credited with points, and whether that play was still under review.
            snapshots[game.id] = GameSnapshot(game: game, previous: snapshots[game.id])

            for event in events where delivered.insert(event.id) {
                if !muted { await deliver(event) }
            }
        }

        // Forget games that have dropped off the slate.
        let ids = Set(current.map(\.id))
        snapshots = snapshots.filter { ids.contains($0.key) }
    }

    /// A poll that came back identical to the last one still counts as having looked:
    /// a halftime with nothing changing must not read as a gap.
    func scoreboardUnchanged() {
        lastScoreboard = .now
    }

    /// Fantasy moments arrive already diffed by `FantasyStore`; the rules decide which
    /// are worth interrupting for and this delivers them through the same de-duplicated
    /// path as the NFL alerts.
    func processFantasy(
        moments: [FantasyMoment],
        matchup: FantasyMatchup,
        settings: FantasyAlertSettings,
        leagueName: String? = nil,
        leagueID: String? = nil
    ) async {
        let events = FantasyAlertRules.events(
            moments: moments, matchup: matchup, settings: settings,
            leagueName: leagueName, leagueID: leagueID
        )
        for event in events where delivered.insert(event.id) {
            await deliver(event)
        }
    }

    // MARK: - Delivery

    private func deliver(_ event: AlertEvent) async {
        guard await isAuthorized() else { return }

        // A banner gives the title and subtitle one line each and the body about two, so
        // the rules put who scored / who has the ball in the first two. The body is often
        // empty on purpose, when repeating the play text would add nothing.
        let content = UNMutableNotificationContent()
        content.title = event.title
        if let subtitle = event.subtitle, !subtitle.isEmpty, subtitle != event.body {
            content.subtitle = subtitle
        }
        if !event.body.isEmpty {
            content.body = event.body
        }
        content.sound = .default
        content.interruptionLevel = .active

        let request = UNNotificationRequest(identifier: event.id, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            NSLog("[FootballWidget] notification failed: \(error.localizedDescription)")
        }
    }

    /// Asks for permission at launch, off the poll path. Asking from inside the first
    /// delivery held that poll — and both poll loops behind it — until the prompt was
    /// answered.
    func requestAuthorization() async {
        // An unbundled binary has no notification identity, and asking would trap.
        guard Bundle.main.bundleIdentifier != nil, !askedForAuthorization else { return }
        askedForAuthorization = true
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])) ?? false
        if !granted { NSLog("[FootballWidget] notifications not authorized") }
    }

    /// Read from the system each time rather than remembered: turning notifications on
    /// in System Settings used to need a relaunch to take effect.
    private func isAuthorized() async -> Bool {
        guard Bundle.main.bundleIdentifier != nil else { return false }
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            Task { await requestAuthorization() }
            return false
        default:
            return false
        }
    }
}

extension Preferences {
    var alertSettings: AlertSettings {
        AlertSettings(
            enabled: alertScope != .off,
            favoritesOnly: alertScope == .favorites,
            favorites: favorites,
            scoring: alertOnScoring,
            turnovers: alertOnTurnover,
            redZone: alertOnRedZone
        )
    }
}
