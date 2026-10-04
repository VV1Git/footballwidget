import SwiftUI
import AppKit
import FootballCore

/// Renders the views to PNG files without ever putting a window on screen.
///
/// `FootballWidget --snapshot <directory>` pulls a real game from ESPN, draws the
/// detail view and field map offscreen with `ImageRenderer`, writes them out and
/// quits. Lets the layout be checked without taking over the display.
@MainActor
enum Snapshot {
    static var requestedDirectory: String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--snapshot"),
              arguments.count > index + 1 else { return nil }
        return arguments[index + 1]
    }

    /// The reconstructed league fixture, loaded from the test bundle's copy on disk so
    /// the app does not have to ship it.
    static func sampleMatchup() -> FantasyMatchup? {
        let candidates = [
            "Tests/FootballCoreTests/Fixtures/league.json",
            FileManager.default.currentDirectoryPath + "/Tests/FootballCoreTests/Fixtures/league.json",
        ]
        for path in candidates {
            guard let data = FileManager.default.contents(atPath: path),
                  let dto = try? JSONDecoder().decode(FantasyLeagueDTO.self, from: data)
            else { continue }
            return FantasyMapper.matchup(from: dto, swid: "{AAAA-1111}")
        }
        return nil
    }

    @discardableResult
    static func write(_ view: some View, to path: String) -> String? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]),
              (try? png.write(to: URL(fileURLWithPath: path))) != nil
        else { return nil }
        return path
    }

    static func run(directory: String) async {
        let client = ESPNClient()
        var written: [String] = []

        do {
            guard case .updated(let games) = try await client.scoreboard() else { return }
            // A completed game has a full play feed to draw.
            guard let game = games.first(where: { $0.phase == .final }) ?? games.first else {
                FileHandle.standardError.write(Data("no games available\n".utf8))
                NSApp.terminate(nil)
                return
            }
            guard case .updated(let detail) = try await client.summary(gameID: game.id) else { return }

            // The drive with the most plays exercises the ladder hardest.
            let busiest = detail.drives.max { $0.plays.count < $1.plays.count }

            guard let drive = busiest else { NSApp.terminate(nil); return }
            let offense = game.team(id: drive.teamID)
            let defense = offense?.id == game.home.id ? game.away : game.home

            for scheme in [ColorScheme.light, .dark] {
                // `ImageRenderer` does not lay out `ScrollView` content and cannot draw
                // Liquid Glass (it needs a live compositor), so the ladder is rendered
                // on its own. Geometry and typography are what this is checking.
                let view = VStack(alignment: .leading, spacing: 8) {
                    Text("\(drive.teamAbbreviation) · \(drive.result) · \(drive.summary)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    FieldLadderView(
                        drive: drive,
                        offense: offense,
                        defense: defense,
                        expandedPlayID: .constant(drive.plays.first(where: { $0.kind == .scrimmage })?.id)
                    )
                }
                .padding(14)
                .frame(width: Metrics.panelWidth, alignment: .leading)
                .environment(\.colorScheme, scheme)
                .background(scheme == .dark ? Color(white: 0.11) : Color(white: 0.97))

                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                guard let image = renderer.nsImage,
                      let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:])
                else { continue }

                let path = "\(directory)/ladder-\(scheme == .dark ? "dark" : "light").png"
                try png.write(to: URL(fileURLWithPath: path))
                written.append(path)
            }

            // Fantasy surfaces, driven by the reconstructed league fixture so the
            // layout can be checked without a connected league.
            if let matchup = sampleMatchup() {
                let fantasyStore = FantasyStore.preview(matchup: matchup)
                let gameStore = GameStore(feed: client)
                for scheme in [ColorScheme.light, .dark] {
                    let view = VStack(alignment: .leading, spacing: 8) {
                        Text("\(matchup.leagueName) · Week \(matchup.week)")
                            .font(.system(size: 12, weight: .semibold))
                        FantasyMatchupContent(matchup: matchup)
                    }
                    .padding(Metrics.gutter)
                        .environment(fantasyStore)
                        .environment(gameStore)
                        .frame(width: Metrics.panelWidth)
                        .environment(\.forcesOpaqueChrome, true)
                        .environment(\.colorScheme, scheme)
                        .background(scheme == .dark ? Color(white: 0.11) : Color(white: 0.97))
                    if let path = write(view, to: "\(directory)/fantasy-\(scheme == .dark ? "dark" : "light").png") {
                        written.append(path)
                    }
                }

                // The ladder again, this time with fantasy credits attached, so the
                // chips can be checked against a real drive.
                let candidates = matchup.allPlayers
                var credits: [String: [PlayAttribution.Credit]] = [:]
                for play in drive.plays where play.kind != .administrative {
                    let found = PlayAttribution.credits(
                        forPlayText: play.text, candidates: candidates,
                        // Drake Maye (4431452) quarterbacks this drive, so give him a
                        // couple of banked plays to prove the chip renders.
                        deltas: [4431452: 4.2, 4430878: 2.7]
                    )
                    if !found.isEmpty { credits[play.id] = found }
                }
                print("ladder credits attached to \(credits.count) of \(drive.plays.count) plays")

                for scheme in [ColorScheme.light, .dark] {
                    let view = VStack(alignment: .leading, spacing: 8) {
                        Text("\(drive.teamAbbreviation) · \(drive.result) — with fantasy credits")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        FieldLadderView(
                            drive: drive, offense: offense, defense: defense,
                            creditsByPlay: credits, expandedPlayID: .constant(nil)
                        )
                    }
                    .padding(14)
                    .frame(width: Metrics.panelWidth, alignment: .leading)
                    .environment(\.forcesOpaqueChrome, true)
                    .environment(\.colorScheme, scheme)
                    .background(scheme == .dark ? Color(white: 0.11) : Color(white: 0.97))
                    if let path = write(view, to: "\(directory)/ladder-fantasy-\(scheme == .dark ? "dark" : "light").png") {
                        written.append(path)
                    }
                }
            }

            // Rows too, so list layout changes can be checked without a window.
            for scheme in [ColorScheme.light, .dark] {
                let rows = VStack(spacing: Metrics.rowSpacing) {
                    ForEach(Array(GameOrdering.sorted(games, favorites: Preferences.shared.favorites).prefix(5))) { g in
                        GameRowView(game: g, onSelect: {}, onToggleFavorite: { _ in })
                    }
                }
                .environment(Preferences.shared)
                .environment(FantasyStore(alerts: AlertEngine()))
                .padding(Metrics.gutter)
                .frame(width: Metrics.panelWidth)
                // Liquid Glass draws nothing under ImageRenderer, so snapshots take the
                // opaque path — which needs checking anyway.
                .environment(\.forcesOpaqueChrome, true)
                .environment(\.colorScheme, scheme)
                .background(scheme == .dark ? Color(white: 0.11) : Color(white: 0.97))

                let renderer = ImageRenderer(content: rows)
                renderer.scale = 2
                if let image = renderer.nsImage,
                   let tiff = image.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    let path = "\(directory)/rows-\(scheme == .dark ? "dark" : "light").png"
                    try png.write(to: URL(fileURLWithPath: path))
                    written.append(path)
                }
            }

            // The ASCII ladder is the same geometry the view draws, so printing it
            // gives a text record of what the picture should contain.
            if let drive = busiest {
                print(FieldGeometry.asciiLadder(for: drive, width: 56))
            }
            print("\nwrote:\n" + written.map { "  \($0)" }.joined(separator: "\n"))
        } catch {
            FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
        }

        NSApp.terminate(nil)
    }
}

// MARK: - RedZone

extension Snapshot {
    static var requestedRedZoneDirectory: String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--snapshot-redzone"),
              arguments.count > index + 1 else { return nil }
        return arguments[index + 1]
    }

    /// `--snapshot-redzone <directory>` draws the RedZone pill and window offscreen from
    /// a made-up Sunday slate. No network: the layout can be checked any day of the week
    /// without asking ESPN for anything.
    static func runRedZone(directory: String) async {
        let before = sampleSlate(kcScore: 10, buffaloBall: false)
        let after = sampleSlate(kcScore: 17, buffaloBall: true)
        let feed = StaticFeed(games: after)
        let gameStore = GameStore(feed: feed)
        await gameStore.refresh()

        let redZone = RedZoneStore()
        let now = Date.now
        redZone.ingest(before, changed: true, now: now.addingTimeInterval(-20))
        redZone.ingest(after, changed: true, now: now)
        let fantasyStore = FantasyStore(alerts: AlertEngine())
        let controller = RedZoneWindowController.shared
        var written: [String] = []

        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            let expanded = RedZoneExpandedView(controller: controller)
                .environment(gameStore)
                .environment(redZone)
                .environment(fantasyStore)
                .environment(Preferences.shared)
                .environment(\.forcesOpaqueChrome, true)
                .environment(\.colorScheme, scheme)
                .background(scheme == .dark ? Color(white: 0.11) : Color(white: 0.97))
            if let path = PanelCapture.captureView(
                expanded, to: "\(directory)/redzone-\(suffix).png",
                size: RedZoneWindowController.expandedSize
            ) {
                written.append(path)
            }

            let pill = RedZonePill(controller: controller)
                .fixedSize()
                .padding(8)
                .environment(gameStore)
                .environment(redZone)
                .environment(\.forcesOpaqueChrome, true)
                .environment(\.colorScheme, scheme)
                .background(scheme == .dark ? Color(white: 0.11) : Color(white: 0.97))
            if let path = write(pill, to: "\(directory)/redzone-pill-\(suffix).png") {
                written.append(path)
            }
        }
        print("featured: \(redZone.spotlightID ?? "none") — \(redZone.spotlightReason)")
        print("moments: " + redZone.moments.map(\.title).joined(separator: " | "))
        print("\nwrote:\n" + written.map { "  \($0)" }.joined(separator: "\n"))
        NSApp.terminate(nil)
    }

    /// Three live games: Kansas City driving in Buffalo's red zone late in a close one,
    /// a Seattle blowout, and Detroit at halftime.
    private static func sampleSlate(kcScore: Int, buffaloBall: Bool) -> [Game] {
        func team(_ id: String, _ abbr: String, _ score: Int, _ hex: String) -> TeamSide {
            TeamSide(id: id, abbreviation: abbr, displayName: abbr, shortName: abbr,
                     score: score, primaryHex: hex)
        }
        let kc = team("12", "KC", kcScore, "e31837")
        let buf = team("2", "BUF", 14, "00338d")
        let featured = Game(
            id: "1", shortName: "KC @ BUF", kickoff: .now.addingTimeInterval(-10_000),
            phase: .live, statusDetail: "", period: 4, displayClock: "2:11",
            home: buf, away: kc,
            situation: buffaloBall
                ? Situation(possessionTeamID: "2", shortDownDistance: "1st & 10",
                            downDistanceText: "1st & 10 at BUF 25", possessionText: "BUF 25",
                            down: 1, distance: 10,
                            lastPlayText: "P.Mahomes pass short middle to T.Kelce for 12 yards, TOUCHDOWN. H.Butker extra point is GOOD, Center-J.Winchester, Holder-M.Araiza.",
                            lastPlayID: "p2", lastPlayWasScoring: true)
                : Situation(possessionTeamID: "12", shortDownDistance: "2nd & 4",
                            downDistanceText: "2nd & 4 at BUF 12", possessionText: "BUF 12",
                            down: 2, distance: 4, isRedZone: true,
                            lastPlayText: "(Shotgun) P.Mahomes pass short right to R.Rice to BUF 12 for 9 yards (T.Bernard).",
                            lastPlayID: "p1")
        )
        let blowout = Game(
            id: "2", shortName: "ARI @ SEA", kickoff: .now.addingTimeInterval(-9_000),
            phase: .live, statusDetail: "", period: 3, displayClock: "8:40",
            home: team("26", "SEA", 31, "002244"), away: team("22", "ARI", 3, "97233f"),
            situation: Situation(possessionTeamID: "26", shortDownDistance: "3rd & 2",
                                 downDistanceText: "3rd & 2 at SEA 40", possessionText: "SEA 40",
                                 down: 3, distance: 2,
                                 lastPlayText: "K.Walker left end to SEA 40 for 4 yards (B.Baker).",
                                 lastPlayID: "s1")
        )
        let halftime = Game(
            id: "3", shortName: "GB @ DET", kickoff: .now.addingTimeInterval(-6_000),
            phase: .halftime, statusDetail: "Halftime", period: 2, displayClock: "0:00",
            home: team("8", "DET", 10, "0076b6"), away: team("9", "GB", 7, "203731")
        )
        return [featured, blowout, halftime]
    }
}

/// A feed that always answers with the same slate, for offscreen rendering.
private struct StaticFeed: GameFeed {
    let games: [Game]
    func scoreboard() async throws -> ESPNClient.Fetch<[Game]> { .updated(games) }
    func summary(gameID: String) async throws -> ESPNClient.Fetch<GameDetail> {
        .updated(GameDetail(gameID: gameID, drives: [], scoringPlayIDs: []))
    }
    func allTeams() async throws -> [ESPNClient.Team] { [] }
}
