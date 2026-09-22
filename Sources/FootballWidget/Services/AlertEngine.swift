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
    private var deliveredIDs: Set<String> = []
    private var authorized: Bool?

    func process(previous: [Game], current: [Game], preferences: Preferences) async {
        let settings = await MainActor.run { preferences.alertSettings }

        for game in current {
            let events = AlertRules.events(
                previous: snapshots[game.id],
                game: game,
                settings: settings
            )
            // Built from the last snapshot so it remembers which play has already been
            // credited with points, and whether that play was still under review.
            snapshots[game.id] = GameSnapshot(game: game, previous: snapshots[game.id])

            for event in events where deliveredIDs.insert(event.id).inserted {
                await deliver(event)
            }
        }

        // Forget games that have dropped off the slate.
        let ids = Set(current.map(\.id))
        snapshots = snapshots.filter { ids.contains($0.key) }

        // The delivered set is only for de-duplication within a session; cap it so a
        // long Sunday cannot grow it without bound.
        if deliveredIDs.count > 500 { deliveredIDs.removeAll() }
    }

    /// Fantasy moments arrive already diffed by `FantasyStore`; the rules decide which
    /// are worth interrupting for and this delivers them through the same de-duplicated
    /// path as the NFL alerts.
    func processFantasy(
        moments: [FantasyMoment],
        matchup: FantasyMatchup,
        settings: FantasyAlertSettings,
        leagueName: String? = nil
    ) async {
        let events = FantasyAlertRules.events(
            moments: moments, matchup: matchup, settings: settings, leagueName: leagueName
        )
        for event in events where deliveredIDs.insert(event.id).inserted {
            await deliver(event)
        }
    }

    // MARK: - Delivery

    private func deliver(_ event: AlertEvent) async {
        guard await ensureAuthorized() else { return }

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

    private func ensureAuthorized() async -> Bool {
        if let authorized { return authorized }
        // An unbundled binary has no notification identity, and asking would trap.
        guard Bundle.main.bundleIdentifier != nil else {
            authorized = false
            return false
        }
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])) ?? false
        authorized = granted
        if !granted { NSLog("[FootballWidget] notifications not authorized") }
        return granted
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
