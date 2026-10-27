import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var authManager = AuthManager.shared

    @State private var launchAtLogin = false
    @AppStorage(PluckkPanel.pushWindowAsideKey) private var pushWindowAside = false
    @AppStorage(SessionTimer.minutesKey) private var practiceMinutes = SessionTimer.defaultMinutes
    @State private var mochiApiKeyInput = ""
    @State private var isSavingMochi = false
    @State private var mochiDecks: [MochiDeck] = []
    @State private var selectedMochiDeckId: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                practiceSection

                Divider()

                // Account Section
                accountSection

                Divider()

                // Mochi Integration
                mochiSection

                Divider()

                // Preferences
                preferencesSection

                Divider()

                // About
                aboutSection
            }
            .padding(16)
        }
        .scrollIndicators(.hidden)
        .onAppear {
            loadSettings()
        }
    }

    // MARK: - Practice Section

    private var practiceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Practice")
                .font(.headline)

            ActivityGrid()

            HStack {
                Text("Timer length")
                Spacer()
                Stepper(value: $practiceMinutes, in: 1...30) {
                    Text("\(practiceMinutes) min").monospacedDigit()
                }
                .fixedSize()
            }
            .font(.callout)
        }
    }

    // MARK: - Account Section

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Account")
                .font(.headline)

            if let user = appState.user {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "person.circle.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.accentColor)

                        VStack(alignment: .leading) {
                            Text(user.displayName ?? user.email)
                                .fontWeight(.medium)
                            Text(user.email)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Button("Sign Out") {
                    authManager.signOut()
                }
                .buttonStyle(.bordered)
                .padding(.top, 4)
            } else {
                Button("Sign In") {
                    authManager.signInWithGoogle()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Mochi Section

    private var mochiSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mochi Integration")
                .font(.headline)

            Text("Optionally sync cards to your Mochi account")
                .font(.caption)
                .foregroundColor(.secondary)

            Toggle("Enable Mochi sync", isOn: $appState.mochiEnabled)

            if appState.mochiEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    Text("API Key")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack {
                        SecureField("Enter Mochi API key", text: $mochiApiKeyInput)
                            .textFieldStyle(.roundedBorder)

                        if isSavingMochi {
                            ProgressView()
                                .scaleEffect(0.7)
                        } else {
                            Button("Save") {
                                saveMochiSettings()
                            }
                            .disabled(mochiApiKeyInput.isEmpty)
                        }
                    }

                    if !mochiDecks.isEmpty {
                        Text("Deck")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Picker("", selection: $selectedMochiDeckId) {
                            Text("Select deck").tag(nil as String?)
                            ForEach(mochiDecks, id: \.id) { deck in
                                Text(deck.name).tag(deck.id as String?)
                            }
                        }
                        .labelsHidden()
                        .onChange(of: selectedMochiDeckId) { newValue in
                            saveMochiDeckSelection(newValue)
                        }
                    }

                    Link("Get API key from mochi.cards", destination: URL(string: "https://app.mochi.cards/settings/api")!)
                        .font(.caption)
                }
            }
        }
    }

    // MARK: - Preferences Section

    private var preferencesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Preferences")
                .font(.headline)

            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { newValue in
                    setLaunchAtLogin(newValue)
                }

            Toggle("Push the active window aside when the panel opens", isOn: $pushWindowAside)
            Text("Off: the panel floats over the app. On: the app's window is resized to make room.")
                .font(.caption)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Trigger")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack {
                    Image(systemName: "command")
                    Image(systemName: "command")
                    Text("Double-tap Command")
                }
                .font(.caption)
                .padding(8)
                .background(Color.primary.opacity(0.05))
                .cornerRadius(6)
            }
        }
    }

    // MARK: - About Section

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("About")
                .font(.headline)

            HStack {
                Text("Pluckk")
                    .fontWeight(.medium)
                Text("v1.0.0")
                    .foregroundColor(.secondary)
            }
            .font(.caption)

            HStack(spacing: 16) {
                Link("Website", destination: URL(string: "https://pluckk.com")!)
                Link("Help", destination: URL(string: "https://pluckk.com/help")!)
            }
            .font(.caption)
        }
    }

    // MARK: - Actions

    private func loadSettings() {
        // Load launch at login status
        if #available(macOS 13.0, *) {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }

        // Load Mochi settings
        if let key = appState.mochiApiKey {
            mochiApiKeyInput = key
            fetchMochiDecks(apiKey: key)
        }
        selectedMochiDeckId = appState.mochiDeckId
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("Failed to set launch at login: \(error)")
                launchAtLogin = !enabled // Revert
            }
        }
    }

    private func saveMochiSettings() {
        guard let token = AuthManager.shared.accessToken else { return }

        isSavingMochi = true

        Task {
            do {
                try await PluckkAPI.shared.updateUser(
                    token: token,
                    updates: ["mochiApiKey": mochiApiKeyInput]
                )

                await MainActor.run {
                    appState.mochiApiKey = mochiApiKeyInput
                    isSavingMochi = false
                    fetchMochiDecks(apiKey: mochiApiKeyInput)
                }
            } catch {
                await MainActor.run {
                    isSavingMochi = false
                }
                print("Failed to save Mochi settings: \(error)")
            }
        }
    }

    private func saveMochiDeckSelection(_ deckId: String?) {
        guard let token = AuthManager.shared.accessToken else { return }

        Task {
            do {
                try await PluckkAPI.shared.updateUser(
                    token: token,
                    updates: ["mochiDeckId": deckId ?? NSNull()]
                )

                await MainActor.run {
                    appState.mochiDeckId = deckId
                }
            } catch {
                print("Failed to save Mochi deck: \(error)")
            }
        }
    }

    private func fetchMochiDecks(apiKey: String) {
        guard let token = AuthManager.shared.accessToken else { return }
        Task {
            do {
                let decks = try await PluckkAPI.shared.fetchMochiDecks(token: token)
                await MainActor.run { mochiDecks = decks }
            } catch {
                print("Failed to fetch Mochi decks: \(error)")
            }
        }
    }
}


#Preview {
    SettingsView()
        .frame(width: 320, height: 600)
}
