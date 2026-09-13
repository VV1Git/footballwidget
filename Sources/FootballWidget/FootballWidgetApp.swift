import SwiftUI
import AppKit
import FootballCore

@main
struct FootballWidgetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store: GameStore
    @State private var fantasy: FantasyStore
    @State private var preferences = Preferences.shared
    /// Keeps the icon visible briefly after launch so "hide when idle" can never
    /// strand the user with no way back into Settings.
    @State private var launchGrace = true

    init() {
        // `--replay [secondsPerPlay]` walks a finished game forward as if it were
        // live, so the live panel, ladder and alerts can be exercised on a day with
        // no football on.
        let arguments = CommandLine.arguments
        let feed: GameFeed
        if let index = arguments.firstIndex(of: "--replay") {
            let pace = arguments.count > index + 1 ? Double(arguments[index + 1]) ?? 1.5 : 1.5
            feed = ReplaySource(secondsPerPlay: pace)
        } else {
            feed = ESPNClient()
        }
        // One alert engine is shared so NFL and fantasy notifications de-duplicate
        // against each other and only ask for authorization once.
        let alerts = AlertEngine()
        let games = GameStore(feed: feed, alerts: alerts)
        let fantasy = FantasyStore(alerts: alerts)
        _store = State(initialValue: games)
        _fantasy = State(initialValue: fantasy)
    }

    var body: some Scene {
        MenuBarExtra(isInserted: iconInserted) {
            PanelRootView()
                .environment(store)
                .environment(fantasy)
                .environment(preferences)
        } label: {
            MenuBarLabel()
                .environment(store)
                .environment(fantasy)
                .environment(preferences)
                .task {
                    if Diagnose.isRequested {
                        fantasy.attach(to: store)
                        await Diagnose.run(store: store, fantasy: fantasy)
                        return
                    }
                    if let path = FantasyDump.requestedPath {
                        await FantasyDump.run(path: path, preferences: preferences)
                        return
                    }
                    if let directory = Snapshot.requestedDirectory {
                        await Snapshot.run(directory: directory)
                        return
                    }
                    // The label is always mounted, so polling starts at launch rather
                    // than waiting for the panel to be opened for the first time.
                    fantasy.attach(to: store)
                    store.start()
                    fantasy.start()
                    if PreviewWindowController.isRequested {
                        PreviewWindowController.show(store: store, fantasy: fantasy, preferences: preferences)
                    }
                    try? await Task.sleep(for: .seconds(60))
                    launchGrace = false
                }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(preferences)
                .environment(store)
                .environment(fantasy)
        }
    }

    private var iconInserted: Binding<Bool> {
        Binding(
            get: {
                // Never report `false` for the command-line tooling modes. SwiftUI maps
                // this binding onto `NSStatusItem.isVisible`, which macOS persists to
                // the app's preferences under "NSStatusItem Visible…" — so a --snapshot
                // or --diagnose run would write "hidden" to disk and the real app would
                // come back with no menu bar icon at all. They insert the icon for the
                // second or two they live instead.
                if store.liveCount > 0 { return true }
                guard preferences.idleBehavior == .hideIcon else { return true }
                return launchGrace
            },
            set: { _ in }
        )
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only — no Dock icon, no window on launch. `LSUIElement` covers this
        // in the bundle; setting it here too keeps `swift run` behaving the same.
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
