import SwiftUI
import FootballCore

struct SettingsView: View {
    var body: some View {
        TabView {
            AlertSettingsView()
                .tabItem { Label("Alerts", systemImage: "bell") }
            FantasySettingsView()
                .tabItem { Label("Fantasy", systemImage: "person.2") }
            FavoritesSettingsView()
                .tabItem { Label("Teams", systemImage: "star") }
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 460, height: 460)
    }
}

// MARK: - Alerts

struct AlertSettingsView: View {
    @Environment(Preferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences

        Form {
            Section {
                Picker("Notify me about", selection: $preferences.alertScope) {
                    ForEach(AlertScope.allCases) { scope in
                        Text(scope.label).tag(scope)
                    }
                }
                .pickerStyle(.radioGroup)
            } footer: {
                Text("Favorite teams are starred from the game list, or on the Teams tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Alert me on") {
                Toggle("Scoring plays", isOn: $preferences.alertOnScoring)
                Toggle("Turnovers", isOn: $preferences.alertOnTurnover)
                Toggle("Red zone entry", isOn: $preferences.alertOnRedZone)
            }
            .disabled(preferences.alertScope == .off)
        }
        .formStyle(.grouped)
    }
}

// MARK: - Favorites

struct FavoritesSettingsView: View {
    @Environment(Preferences.self) private var preferences
    @Environment(GameStore.self) private var store

    private let columns = [GridItem(.adaptive(minimum: 120), spacing: 6)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Favorites sort to the top of the list, and can be the only games that raise alerts.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 14)

            if store.teams.isEmpty {
                ProgressView("Loading teams…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(store.teams) { team in
                            teamToggle(team)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                }
            }
        }
    }

    private func teamToggle(_ team: ESPNClient.Team) -> some View {
        let isOn = preferences.isFavorite(team.abbreviation)
        return Button {
            preferences.toggleFavorite(team.abbreviation)
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(espnHex: team.colorHex) ?? .gray)
                    .frame(width: 8, height: 8)
                Text(team.abbreviation)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 30, alignment: .leading)
                Text(team.displayName.components(separatedBy: " ").last ?? "")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: isOn ? "star.fill" : "star")
                    .font(.system(size: 9))
                    .foregroundStyle(isOn ? AnyShapeStyle(Color.yellow) : AnyShapeStyle(.tertiary))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(.rect)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.primary.opacity(isOn ? 0.08 : 0.03))
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @Environment(Preferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences

        Form {
            Section {
                Picker("When nothing is live", selection: $preferences.idleBehavior) {
                    ForEach(IdleBehavior.allCases) { behavior in
                        Text(behavior.label).tag(behavior)
                    }
                }
                .pickerStyle(.radioGroup)
            } footer: {
                Text(preferences.idleBehavior.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Launch at login", isOn: $preferences.launchAtLogin)
                    .disabled(!preferences.launchAtLoginAvailable)
                if !preferences.launchAtLoginAvailable {
                    Text("Available once the app is installed in /Applications.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent("Data") {
                    Text("ESPN public API")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Version") {
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
