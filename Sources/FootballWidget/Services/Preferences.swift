import Foundation
import Observation
import ServiceManagement
import FootballCore

/// Which games are allowed to raise a notification.
public enum AlertScope: String, CaseIterable, Identifiable, Sendable {
    case all, favorites, off
    public var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All games"
        case .favorites: return "Favorite teams only"
        case .off: return "Off"
        }
    }
}

/// What the menu bar does when nothing is being played.
public enum IdleBehavior: String, CaseIterable, Identifiable, Sendable {
    case showSchedule, hideIcon, countdown, fantasyScore
    public var id: String { rawValue }

    var label: String {
        switch self {
        case .showSchedule: return "Dimmed icon, schedule in the panel"
        case .hideIcon: return "Hide the icon entirely"
        case .countdown: return "Icon with a countdown to kickoff"
        case .fantasyScore: return "Icon with my fantasy score"
        }
    }

    var detail: String {
        switch self {
        case .showSchedule: return "Always reachable. Opening it shows today's finals and kickoff times."
        case .hideIcon: return "The icon reappears when a game goes live, and for a minute after launch so Settings stays reachable."
        case .countdown: return "Counts down to the next kickoff, updating every minute."
        case .fantasyScore: return "Shows your matchup, e.g. 78.2 – 71.5. Needs a connected league; while games are live the count of live games takes over."
        }
    }
}

@Observable
final class Preferences {
    static let shared = Preferences()

    private let defaults: UserDefaults
    private enum Key {
        static let alertScope = "alertScope"
        static let alertScoring = "alertScoring"
        static let alertTurnover = "alertTurnover"
        static let alertRedZone = "alertRedZone"
        static let idleBehavior = "idleBehavior"
        static let favorites = "favoriteTeamAbbreviations"
        static let launchAtLogin = "launchAtLogin"
        static let fantasyLeagueIDs = "fantasyLeagueIDs"
        static let activeFantasyLeagueID = "activeFantasyLeagueID"
        /// Pre-multi-league key, read once so an existing connection is not lost.
        static let legacyFantasyLeagueID = "fantasyLeagueID"
        static let fantasyAlerts = "fantasyAlertsEnabled"
        static let fantasyThreshold = "fantasyAlertThreshold"
        static let collapsedSections = "collapsedSections"
        static let showsAllPlayText = "showsAllPlayText"
        static let redZoneOpen = "redZoneOpen"
        static let redZoneMini = "redZoneMini"
        static let redZoneCorner = "redZoneCorner"
        static let redZoneDisplayID = "redZoneDisplayID"
        static let redZoneOddsHidden = "redZoneOddsHidden"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        _alertScope = AlertScope(rawValue: defaults.string(forKey: Key.alertScope) ?? "") ?? .all
        _alertOnScoring = defaults.object(forKey: Key.alertScoring) as? Bool ?? true
        _alertOnTurnover = defaults.object(forKey: Key.alertTurnover) as? Bool ?? true
        _alertOnRedZone = defaults.object(forKey: Key.alertRedZone) as? Bool ?? true
        _idleBehavior = IdleBehavior(rawValue: defaults.string(forKey: Key.idleBehavior) ?? "") ?? .showSchedule
        _favorites = Set(defaults.stringArray(forKey: Key.favorites) ?? [])
        // Adopt the single league that older versions stored, so adding multi-league
        // support does not silently sign anyone out of the league they already had.
        var leagues = defaults.stringArray(forKey: Key.fantasyLeagueIDs) ?? []
        if leagues.isEmpty,
           let legacy = defaults.string(forKey: Key.legacyFantasyLeagueID),
           !legacy.isEmpty {
            leagues = [legacy]
            defaults.set(leagues, forKey: Key.fantasyLeagueIDs)
        }
        _fantasyLeagueIDs = leagues
        _activeFantasyLeagueID = defaults.string(forKey: Key.activeFantasyLeagueID)
            ?? leagues.first ?? ""
        _fantasyAlertsEnabled = defaults.object(forKey: Key.fantasyAlerts) as? Bool ?? true
        _fantasyThreshold = defaults.object(forKey: Key.fantasyThreshold) as? Double ?? 6.0
        _collapsedSections = Set(defaults.stringArray(forKey: Key.collapsedSections) ?? [])
        _showsAllPlayText = defaults.object(forKey: Key.showsAllPlayText) as? Bool ?? false
        _redZoneOpen = defaults.object(forKey: Key.redZoneOpen) as? Bool ?? false
        _redZoneMini = defaults.object(forKey: Key.redZoneMini) as? Bool ?? false
        _redZoneCorner = defaults.string(forKey: Key.redZoneCorner) ?? "bottomRight"
        _redZoneDisplayID = defaults.object(forKey: Key.redZoneDisplayID) as? Int ?? 0
        _redZoneOddsHidden = defaults.object(forKey: Key.redZoneOddsHidden) as? Bool ?? false
    }

    // Backing storage is written through on every change so the app has no separate
    // "save" step; @Observable handles telling SwiftUI.

    private var _alertScope: AlertScope
    var alertScope: AlertScope {
        get { access(keyPath: \.alertScope); return _alertScope }
        set { withMutation(keyPath: \.alertScope) {
            _alertScope = newValue
            defaults.set(newValue.rawValue, forKey: Key.alertScope)
        } }
    }

    private var _alertOnScoring: Bool
    var alertOnScoring: Bool {
        get { access(keyPath: \.alertOnScoring); return _alertOnScoring }
        set { withMutation(keyPath: \.alertOnScoring) {
            _alertOnScoring = newValue
            defaults.set(newValue, forKey: Key.alertScoring)
        } }
    }

    private var _alertOnTurnover: Bool
    var alertOnTurnover: Bool {
        get { access(keyPath: \.alertOnTurnover); return _alertOnTurnover }
        set { withMutation(keyPath: \.alertOnTurnover) {
            _alertOnTurnover = newValue
            defaults.set(newValue, forKey: Key.alertTurnover)
        } }
    }

    private var _alertOnRedZone: Bool
    var alertOnRedZone: Bool {
        get { access(keyPath: \.alertOnRedZone); return _alertOnRedZone }
        set { withMutation(keyPath: \.alertOnRedZone) {
            _alertOnRedZone = newValue
            defaults.set(newValue, forKey: Key.alertRedZone)
        } }
    }

    private var _idleBehavior: IdleBehavior
    var idleBehavior: IdleBehavior {
        get { access(keyPath: \.idleBehavior); return _idleBehavior }
        set { withMutation(keyPath: \.idleBehavior) {
            _idleBehavior = newValue
            defaults.set(newValue.rawValue, forKey: Key.idleBehavior)
        } }
    }

    /// Team abbreviations, e.g. "KC". Abbreviations rather than ESPN ids so the stored
    /// value stays readable and survives an id reshuffle.
    private var _favorites: Set<String>
    var favorites: Set<String> {
        get { access(keyPath: \.favorites); return _favorites }
        set { withMutation(keyPath: \.favorites) {
            _favorites = newValue
            defaults.set(Array(newValue).sorted(), forKey: Key.favorites)
        } }
    }

    func isFavorite(_ abbreviation: String) -> Bool { favorites.contains(abbreviation) }

    func toggleFavorite(_ abbreviation: String) {
        var next = favorites
        if next.contains(abbreviation) { next.remove(abbreviation) } else { next.insert(abbreviation) }
        favorites = next
    }

    /// Sections the user has folded away, by `GameSectionKind.rawValue`. Stored so the
    /// panel opens the way it was left.
    private var _collapsedSections: Set<String>
    var collapsedSections: Set<String> {
        get { access(keyPath: \.collapsedSections); return _collapsedSections }
        set { withMutation(keyPath: \.collapsedSections) {
            _collapsedSections = newValue
            defaults.set(Array(newValue).sorted(), forKey: Key.collapsedSections)
        } }
    }

    /// Show every play's description at once, rather than opening them one at a time.
    private var _showsAllPlayText: Bool
    var showsAllPlayText: Bool {
        get { access(keyPath: \.showsAllPlayText); return _showsAllPlayText }
        set { withMutation(keyPath: \.showsAllPlayText) {
            _showsAllPlayText = newValue
            defaults.set(newValue, forKey: Key.showsAllPlayText)
        } }
    }

    func isCollapsed(_ kind: GameSectionKind) -> Bool {
        collapsedSections.contains(kind.rawValue)
    }

    func toggleSection(_ kind: GameSectionKind) {
        var next = collapsedSections
        if next.contains(kind.rawValue) {
            next.remove(kind.rawValue)
        } else {
            next.insert(kind.rawValue)
        }
        collapsedSections = next
    }

    // MARK: - RedZone

    // Stored so RedZone comes back the way it was left: open or not, pill or full size,
    // and in which corner of which display.

    /// Whether the user has RedZone switched on. It is only on screen while a game is live.
    private var _redZoneOpen: Bool
    var redZoneOpen: Bool {
        get { access(keyPath: \.redZoneOpen); return _redZoneOpen }
        set { withMutation(keyPath: \.redZoneOpen) {
            _redZoneOpen = newValue
            defaults.set(newValue, forKey: Key.redZoneOpen)
        } }
    }

    /// Shrunk to the one-line pill rather than the full window.
    private var _redZoneMini: Bool
    var redZoneMini: Bool {
        get { access(keyPath: \.redZoneMini); return _redZoneMini }
        set { withMutation(keyPath: \.redZoneMini) {
            _redZoneMini = newValue
            defaults.set(newValue, forKey: Key.redZoneMini)
        } }
    }

    /// A `ScreenCorner` raw value.
    private var _redZoneCorner: String
    var redZoneCorner: String {
        get { access(keyPath: \.redZoneCorner); return _redZoneCorner }
        set { withMutation(keyPath: \.redZoneCorner) {
            _redZoneCorner = newValue
            defaults.set(newValue, forKey: Key.redZoneCorner)
        } }
    }

    /// The display it was last placed on, as a `CGDirectDisplayID`; 0 when not known.
    private var _redZoneDisplayID: Int
    var redZoneDisplayID: Int {
        get { access(keyPath: \.redZoneDisplayID); return _redZoneDisplayID }
        set { withMutation(keyPath: \.redZoneDisplayID) {
            _redZoneDisplayID = newValue
            defaults.set(newValue, forKey: Key.redZoneDisplayID)
        } }
    }

    /// The RedZone odds blurred, for watching without knowing who the market favours.
    private var _redZoneOddsHidden: Bool
    var redZoneOddsHidden: Bool {
        get { access(keyPath: \.redZoneOddsHidden); return _redZoneOddsHidden }
        set { withMutation(keyPath: \.redZoneOddsHidden) {
            _redZoneOddsHidden = newValue
            defaults.set(newValue, forKey: Key.redZoneOddsHidden)
        } }
    }

    // MARK: - Fantasy

    /// Connected leagues, in the order they were added. The cookies live in
    /// CredentialStore; one ESPN account's pair works for every league it is in, so
    /// only the list of ids is ordinary settings.
    private var _fantasyLeagueIDs: [String]
    var fantasyLeagueIDs: [String] {
        get { access(keyPath: \.fantasyLeagueIDs); return _fantasyLeagueIDs }
        set { withMutation(keyPath: \.fantasyLeagueIDs) {
            _fantasyLeagueIDs = newValue
            defaults.set(newValue, forKey: Key.fantasyLeagueIDs)
        } }
    }

    /// Which league the matchup view, the menu bar and the in-game lists follow.
    private var _activeFantasyLeagueID: String
    var activeFantasyLeagueID: String {
        get {
            access(keyPath: \.activeFantasyLeagueID)
            // Fall back to the first connected league if the remembered one is gone.
            if _fantasyLeagueIDs.contains(_activeFantasyLeagueID) { return _activeFantasyLeagueID }
            return _fantasyLeagueIDs.first ?? ""
        }
        set { withMutation(keyPath: \.activeFantasyLeagueID) {
            _activeFantasyLeagueID = newValue
            defaults.set(newValue, forKey: Key.activeFantasyLeagueID)
        } }
    }

    func addFantasyLeague(_ id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var next = fantasyLeagueIDs
        if !next.contains(trimmed) { next.append(trimmed) }
        fantasyLeagueIDs = next
        activeFantasyLeagueID = trimmed
    }

    func removeFantasyLeague(_ id: String) {
        fantasyLeagueIDs = fantasyLeagueIDs.filter { $0 != id }
        if activeFantasyLeagueID == id {
            activeFantasyLeagueID = fantasyLeagueIDs.first ?? ""
        }
    }

    private var _fantasyAlertsEnabled: Bool
    var fantasyAlertsEnabled: Bool {
        get { access(keyPath: \.fantasyAlertsEnabled); return _fantasyAlertsEnabled }
        set { withMutation(keyPath: \.fantasyAlertsEnabled) {
            _fantasyAlertsEnabled = newValue
            defaults.set(newValue, forKey: Key.fantasyAlerts)
        } }
    }

    /// Points a single play must be worth to interrupt you, when it is not a touchdown.
    private var _fantasyThreshold: Double
    var fantasyThreshold: Double {
        get { access(keyPath: \.fantasyThreshold); return _fantasyThreshold }
        set { withMutation(keyPath: \.fantasyThreshold) {
            _fantasyThreshold = newValue
            defaults.set(newValue, forKey: Key.fantasyThreshold)
        } }
    }

    var fantasyAlertSettings: FantasyAlertSettings {
        FantasyAlertSettings(
            // Fantasy alerts also respect the master scope switch: "Off" means off.
            enabled: fantasyAlertsEnabled && alertScope != .off,
            threshold: fantasyThreshold,
            startersOnly: true
        )
    }

    // MARK: - Launch at login

    var launchAtLogin: Bool {
        get {
            access(keyPath: \.launchAtLogin)
            return SMAppService.mainApp.status == .enabled
        }
        set {
            withMutation(keyPath: \.launchAtLogin) {
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                    defaults.set(newValue, forKey: Key.launchAtLogin)
                } catch {
                    NSLog("[FootballWidget] launch at login failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Registering only works from a real bundle in /Applications, so the toggle is
    /// disabled while running the raw binary out of .build.
    var launchAtLoginAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }
}
