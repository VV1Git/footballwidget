import SwiftUI
import AppKit
import FootballCore

struct FantasySettingsView: View {
    @Environment(Preferences.self) private var preferences
    @Environment(FantasyStore.self) private var fantasy

    @State private var setupCode = ""
    @State private var codeStatus: CodeStatus = .idle
    @State private var showingManual = false
    @State private var didCopyCommand = false

    // Manual entry, for when the snippet cannot read the cookies.
    @State private var leagueInput = ""
    @State private var espnS2 = ""
    @State private var swid = ""

    private enum CodeStatus: Equatable {
        case idle
        case accepted(league: String)
        case badCode
    }

    var body: some View {
        @Bindable var preferences = preferences

        Form {
            if !fantasy.leagueIDs.isEmpty {
                Section("Your leagues") {
                    ForEach(fantasy.leagueIDs, id: \.self) { leagueID in
                        leagueRow(leagueID)
                    }
                    Text("One ESPN sign-in covers every league you are in, so adding another needs only its league ID or URL.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                quickSetup
            } header: {
                Text(fantasy.leagueIDs.isEmpty ? "Connect your league" : "Add another league")
            } footer: {
                instructions
            }

            Section(isExpanded: $showingManual) {
                manualEntry
            } header: {
                HStack {
                    Text("Enter it by hand instead")
                    Spacer()
                    Button(showingManual ? "Hide" : "Show") {
                        withAnimation(.snappy) { showingManual.toggle() }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }

            Section("Alerts") {
                Toggle("Notify me about fantasy scoring", isOn: $preferences.fantasyAlertsEnabled)
                HStack {
                    Text("Alert threshold")
                    Spacer()
                    Text("\(String(format: "%.0f", preferences.fantasyThreshold)) pts")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $preferences.fantasyThreshold, in: 2...15, step: 1)
                    .disabled(!preferences.fantasyAlertsEnabled)
                Text("Touchdowns by a starter always alert. Other plays alert once they are worth at least this much.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Menu bar") {
                Text("To show your fantasy score in the menu bar, pick “Icon with my fantasy score” under Settings › General › When nothing is live.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: loadExisting)
    }

    /// One connected league: name, status, and the controls to select or drop it.
    @ViewBuilder
    private func leagueRow(_ leagueID: String) -> some View {
        let isActive = fantasy.activeLeagueID == leagueID
        HStack(spacing: 8) {
            Button {
                fantasy.selectLeague(leagueID)
            } label: {
                Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            }
            .buttonStyle(.plain)
            .help(isActive ? "Shown in the menu bar and the matchup view"
                           : "Show this league in the menu bar and the matchup view")

            VStack(alignment: .leading, spacing: 1) {
                Text(fantasy.matchup(for: leagueID)?.leagueName ?? "League \(leagueID)")
                    .font(.system(size: 12, weight: .medium))
                Text(statusLine(for: leagueID))
                    .font(.caption)
                    .foregroundStyle(statusColor(for: leagueID))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Button {
                fantasy.remove(leagueID: leagueID)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Remove this league")
        }
    }

    private func statusLine(for leagueID: String) -> String {
        switch fantasy.state(for: leagueID) {
        case .connected:
            guard let matchup = fantasy.matchup(for: leagueID) else { return "Connected" }
            let opponent = matchup.opponent?.name ?? "bye"
            return "\(matchup.mine.name) — \(matchup.compactScore) vs \(opponent)"
        case .connecting: return "Connecting…"
        case .notConfigured: return "Not connected"
        case .failed(let message): return message
        }
    }

    private func statusColor(for leagueID: String) -> Color {
        switch fantasy.state(for: leagueID) {
        case .connected: return .secondary
        case .failed: return .orange
        default: return .secondary
        }
    }

    // MARK: - One-paste setup

    private var quickSetup: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    copyCommand()
                } label: {
                    Label(didCopyCommand ? "Copied!" : "1. Copy command",
                          systemImage: didCopyCommand ? "checkmark" : "doc.on.doc")
                }
                .disabled(didCopyCommand)

                Button {
                    openESPN()
                } label: {
                    Label("2. Open ESPN", systemImage: "safari")
                }

                Spacer()
            }

            HStack(spacing: 6) {
                TextField("3. Paste the code here", text: $setupCode,
                          prompt: Text("FW1.…"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(applyCode)
                Button(fantasy.leagueIDs.isEmpty ? "Connect" : "Add", action: applyCode)
                    .disabled(setupCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            statusRow
        }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 4) {
            step("1", "Press **Copy command**. It goes to your clipboard.")
            step("2", "Press **Open ESPN**, sign in if needed, and go to *your league's* page.")
            step("3", "Open the browser console — **⌥⌘J** in Chrome, **⌥⌘C** in Safari — paste, press Return.")
            step("4", "It copies a code beginning with **FW1** — paste that above and press Connect.")
            Text("The command only reads ESPN's own cookies from the page you are on. Nothing is sent anywhere except to ESPN. The cookies are saved in a file only your user account can read.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3)
            Text("Safari needs its developer tools switched on first: Safari → Settings → Advanced → “Show features for web developers”.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    private func step(_ number: String, _ markdown: String) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Text(number)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
            Text(.init(markdown))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Manual fallback

    private var manualEntry: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("League URL or ID", text: $leagueInput,
                      prompt: Text("fantasy.espn.com/football/team?leagueId=…"))
                .textFieldStyle(.roundedBorder)
            SecureField("espn_s2", text: $espnS2)
                .textFieldStyle(.roundedBorder)
            SecureField("SWID", text: $swid, prompt: Text("{XXXXXXXX-…}"))
                .textFieldStyle(.roundedBorder)

            HStack {
                Button(fantasy.leagueIDs.isEmpty ? "Connect" : "Add") { connectManually() }
                    .disabled(leagueInput.trimmingCharacters(in: .whitespaces).isEmpty)
                if fantasy.isConfigured {
                    Button("Sign out", role: .destructive) { disconnect() }
                        .help("Forget every league and the stored ESPN cookies")
                }
            }

            Text("Both cookies are in your browser's developer tools under Storage (Safari) or Application (Chrome) → Cookies → fantasy.espn.com.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Status

    @ViewBuilder
    private var statusRow: some View {
        switch (codeStatus, fantasy.state) {
        case (.badCode, _):
            label("That doesn't look like a setup code. It should start with FW1.",
                  "exclamationmark.triangle.fill", .orange)
        case (_, .connected):
            if let matchup = fantasy.matchup {
                label("Connected to \(matchup.leagueName) — \(matchup.mine.name)",
                      "checkmark.circle.fill", .green)
            } else {
                label("Connected", "checkmark.circle.fill", .green)
            }
        case (_, .connecting):
            label("Connecting…", "arrow.trianglehead.2.clockwise", .secondary)
        case (_, .failed(let message)):
            label(message, "exclamationmark.triangle.fill", .orange)
        case (.accepted(let league), _):
            label("Code accepted for league \(league). Connecting…",
                  "checkmark.circle", .secondary)
        case (.idle, .notConfigured):
            label("Not connected", "circle.dashed", .secondary)
        }
    }

    private func label(_ text: String, _ symbol: String, _ color: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Actions

    private func copyCommand() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(FantasySetupCodeParser.browserCommand, forType: .string)
        didCopyCommand = true
        // Reset so the button is usable again if they need a second go.
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            didCopyCommand = false
        }
    }

    private func openESPN() {
        if let url = URL(string: "https://fantasy.espn.com/football/team") {
            NSWorkspace.shared.open(url)
        }
    }

    private func applyCode() {
        let raw = setupCode
        guard let code = FantasySetupCodeParser.parse(raw) else {
            codeStatus = .badCode
            return
        }

        // The snippet only finds a league id if it was run on a league page; fall back
        // to whatever was typed in the manual field.
        let league = !code.leagueID.isEmpty
            ? code.leagueID
            : (FantasyClient.parseLeagueID(from: leagueInput) ?? "")

        CredentialStore.write(code.espnS2, for: .espnS2)
        CredentialStore.write(FantasyClient.bracedSWID(code.swid), for: .swid)
        preferences.addFantasyLeague(league)

        leagueInput = ""
        swid = FantasyClient.bracedSWID(code.swid)
        espnS2 = "••••••••••••••••"
        setupCode = ""
        codeStatus = .accepted(league: league.isEmpty ? "—" : league)

        fantasy.reconnect()
    }

    private func loadExisting() {
        leagueInput = ""
        espnS2 = CredentialStore.read(.espnS2) == nil ? "" : "••••••••••••••••"
        swid = CredentialStore.read(.swid) ?? ""
    }

    private func connectManually() {
        guard let leagueID = FantasyClient.parseLeagueID(from: leagueInput) else { return }
        preferences.addFantasyLeague(leagueID)
        leagueInput = ""

        // An untouched placeholder means "keep what is already stored".
        if !espnS2.isEmpty && !espnS2.hasPrefix("••") {
            CredentialStore.write(espnS2, for: .espnS2)
        }
        if !swid.isEmpty {
            CredentialStore.write(FantasyClient.bracedSWID(swid), for: .swid)
            swid = FantasyClient.bracedSWID(swid)
        }
        codeStatus = .idle
        fantasy.reconnect()
    }

    private func disconnect() {
        fantasy.disconnect()
        leagueInput = ""
        espnS2 = ""
        swid = ""
        setupCode = ""
        codeStatus = .idle
    }
}
