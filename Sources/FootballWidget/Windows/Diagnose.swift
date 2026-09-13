import Foundation
import SwiftUI
import AppKit
import FootballCore

/// Prints what the app currently believes, straight out of the real store.
///
/// `FootballWidget --diagnose` runs one live refresh through the same code path the
/// panel uses and dumps the result, so "it isn't showing a game" can be answered with
/// evidence instead of guesswork.
@MainActor
enum Diagnose {
    static var isRequested: Bool { CommandLine.arguments.contains("--diagnose") }

    /// Exercises the ordinary startup path — `store.start()` and nothing else — rather
    /// than forcing a refresh, so it reproduces what the app really does when launched
    /// from the Finder.
    static var usesNormalStartup: Bool { CommandLine.arguments.contains("--as-launched") }

    static func run(store: GameStore, fantasy: FantasyStore) async {
        if usesNormalStartup {
            print("=== normal startup path (store.start() only) ===")
            store.start()
            fantasy.start()
            for second in 1...12 {
                try? await Task.sleep(for: .seconds(1))
                print("  t+\(second)s  games=\(store.games.count)  error=\(store.errorMessage ?? "none")")
                if store.games.count > 0 && second >= 3 { break }
            }
        } else {
            print("=== forced refresh ===")
            store.focus = .list
            await store.refresh()
        }

        print("error:        \(store.errorMessage ?? "none")")
        print("lastUpdated:  \(store.lastUpdated.map(String.init(describing:)) ?? "never")")
        print("games:        \(store.games.count)")
        print("live:         \(store.liveCount)")
        print("nextKickoff:  \(store.nextKickoff.map(String.init(describing:)) ?? "none")")
        let interval = RefreshPolicy.interval(games: store.games, focus: .list)
        print("pollInterval: \(interval)")

        print("\n=== sortedGames (what the panel lists, in order) ===")
        for (index, game) in store.sortedGames.enumerated() {
            let kickoff = game.kickoff.map {
                let f = DateFormatter()
                f.dateFormat = "E d MMM h:mm a"
                return f.string(from: $0)
            } ?? "—"
            // %s takes a C string; handing it a Swift String segfaults in strlen.
            func pad(_ text: String, _ width: Int) -> String {
                text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
            }
            print("\(pad("\(index + 1).", 4))\(pad(game.shortName, 15))"
                  + "\(pad(game.phase.rawValue, 10))\(pad(kickoff, 22))\(game.statusDetail)")
        }

        if let live = store.sortedGames.first(where: { $0.isLive }) {
            print("\n=== 'Your matchup in this game' for \(live.shortName) ===")
            for entry in fantasy.players(inGame: live) {
                print("  \(entry.isMine ? "mine" : "opp ")  \(entry.player.slot.label)  "
                      + "\(entry.player.fullName)  \(entry.player.points)"
                      + (entry.player.isStarter ? "" : "   <-- BENCH, should not be here"))
            }
            print("  badge count: \(fantasy.myPlayerCount(inGame: live))")

            if let detail = store.detail(id: live.id) {
                var chipped = 0
                for drive in detail.drives {
                    for play in drive.plays {
                        let credits = fantasy.credits(forPlay: play.id)
                        guard !credits.isEmpty else { continue }
                        chipped += 1
                        for credit in credits {
                            print("    chip: \(credit.isMine ? "mine" : "opp ") "
                                  + "\(credit.playerName) \(credit.points.map { String(format: "%+.1f", $0) } ?? "-")")
                        }
                    }
                }
                print("  plays with a chip: \(chipped)")
            }
        }

        print("\n=== panel layout, sizing to content like MenuBarExtra does ===")
        if let path = PanelCapture.capture(store: store, fantasy: fantasy,
                                           to: "/tmp/football-panel-auto.png") {
            print("  wrote \(path)")
        }
        print("=== panel layout, with an explicit height ===")
        if let path = PanelCapture.capture(store: store, fantasy: fantasy,
                                           to: "/tmp/football-panel-fixed.png",
                                           forcedHeight: 620) {
            print("  wrote \(path)")
        }

        print("\n=== pinned window at a range of sizes ===")
        // Prefer a game with a real play feed, so the ladder is exercised at each size.
        if let game = store.sortedGames.first(where: { $0.phase == .final || $0.isLive })
            ?? store.sortedGames.first {
            await store.refreshDetail(id: game.id)
            for size in [CGSize(width: 293, height: 400),
                         CGSize(width: 170, height: 64),
                         CGSize(width: 260, height: 200),
                         CGSize(width: 320, height: 360),
                         CGSize(width: 460, height: 560)] {
                let view = GameDetailView(game: game, detail: store.detail(id: game.id))
                    .environment(fantasy)
                    .environment(Preferences.shared)
                    .environment(\.forcesOpaqueChrome, true)
                    .background(Color(white: 0.12))
                let name = "/tmp/pinned-\(Int(size.width))x\(Int(size.height)).png"
                if let path = PanelCapture.captureView(view, to: name, size: size) {
                    print("  \(path)")
                }
            }
        }

        if let game = store.sortedGames.first(where: { $0.isLive || $0.phase == .final }),
           let detail = store.detail(id: game.id),
           let drive = detail.drives.first(where: { !$0.isCurrent && $0.outcome != nil })
                       ?? detail.drives.first {
            let offense = game.team(id: drive.teamID)
            let defense = offense?.id == game.home.id ? game.away : game.home
            // The longest description in the drive, to prove wrapping rather than clipping.
            let longest = drive.plays.filter { $0.kind != .administrative }
                .max { $0.text.count < $1.text.count }
            let opened = longest?.id
            print("  drive: \(drive.teamAbbreviation) | result=\(drive.result) "
                  + "| outcome=\(drive.outcome ?? "nil") | turnover=\(drive.endedInTurnover) "
                  + "| endText=\(drive.endText ?? "nil")")

            for (name, expanded, all) in [("collapsed", String?.none, false),
                                          ("expanded", opened, false),
                                          ("allText", String?.none, true)] {
                let width = CGFloat(300)
                let view = FieldLadderView(
                    drive: drive, offense: offense, defense: defense,
                    creditsByPlay: [:], showsAllText: all, width: width - 20,
                    expandedPlayID: .constant(expanded)
                )
                .padding(10)
                .frame(width: width)
                .environment(\.forcesOpaqueChrome, true)
                .background(Color(white: 0.12))
                if let path = PanelCapture.captureView(view, to: "/tmp/ladder-\(name).png",
                                                       size: CGSize(width: width, height: 420)) {
                    print("  \(path)")
                }
            }
        }

        let settings = FantasySettingsView()
            .environment(Preferences.shared)
            .environment(fantasy)
        if let path = PanelCapture.captureView(settings, to: "/tmp/football-settings.png",
                                               size: CGSize(width: 460, height: 620)) {
            print("settings rendered to \(path)")
        }

        print("\n=== fantasy ===")
        print("configured:   \(fantasy.isConfigured)")
        await fantasy.refresh()
        print("state:        \(fantasy.state)")

        if let matchup = fantasy.matchup {
            print("league:       \(matchup.leagueName)  week \(matchup.week)")
            print("me:           \(matchup.mine.name)  total=\(matchup.mine.points)")
            print("opponent:     \(matchup.opponent?.name ?? "—")  total=\(matchup.opponent?.points ?? -1)")
            for (label, team) in [("MINE", matchup.mine), ("OPP", matchup.opponent)].compactMap({ pair in
                pair.1.map { (pair.0, $0) }
            }) {
                print("  \(label) roster (\(team.roster.count)):")
                for player in team.roster {
                    print(String(format: "    %-5@ %-24@ pts=%-7.2f team=%@",
                                 player.slot.label as NSString,
                                 player.fullName as NSString,
                                 player.points,
                                 player.proTeamID.map(String.init) ?? "-" as String))
                }
            }
        }

        NSApp.terminate(nil)
    }
}
