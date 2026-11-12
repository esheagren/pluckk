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

                SiteGateSettings()

                Divider()

                AssistantSettingsSection()

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
            FilesLocationSetting()
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

/// Which sites stay closed until the day's cards are done, and how long finishing opens them for.
struct SiteGateSettings: View {
    @AppStorage(SiteGate.enabledKey) private var enabled = true
    @AppStorage(SiteGate.sitesKey) private var sites = SiteGate.defaultSites
    @AppStorage(SiteGate.minutesKey) private var minutes = SiteGate.defaultMinutes
    @ObservedObject private var gate = SiteGate.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Earn your sites").font(.headline)
            Toggle("Keep these sites closed until today's cards are done", isOn: $enabled)
            TextField("youtube.com, x.com", text: $sites)
                .textFieldStyle(.roundedBorder)
                .disabled(!enabled)
            Stepper("Finishing opens them for \(minutes) minute\(minutes == 1 ? "" : "s")", value: $minutes, in: 1...60)
                .disabled(!enabled)
            Text("Works in Chrome, Brave, Edge, Arc and Safari while Pluckk is running. After the first window of the day, each new one takes \(SiteGate.cardsPerWindow) more cards; once the day's cards are done, a later batch doesn't lock the sites again, and a practice session of \(SiteGate.sessionMinutes) minutes or more earns a window. macOS asks once per browser to let Pluckk control it. Turn on Launch at login below so the gate is always up.")
                .font(.caption)
                .foregroundColor(.secondary)
            if let problem = gate.permissionProblem {
                Text(problem).font(.caption).foregroundColor(PluckkTheme.Dark.warning)
            }
        }
    }
}


/// Where card pictures, audio and your own modules live: this Mac, or iCloud Drive so other Macs
/// signed in to the same iCloud share them. Switching copies the files across first.
struct FilesLocationSetting: View {
    @State private var inICloud = UserDefaults.standard.bool(forKey: PluckkFiles.iCloudKey)
    @State private var problem: String?
    @State private var moving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Keep pictures, audio and your modules in iCloud Drive", isOn: Binding(
                get: { inICloud },
                set: { want in
                    guard !moving else { return }
                    moving = true
                    problem = nil
                    Task.detached {
                        let failure: String?
                        do { try PluckkFiles.moveFiles(toICloud: want); failure = nil }
                        catch { failure = PluckkFiles.iCloudFolder == nil ? "iCloud Drive is off on this Mac." : error.localizedDescription }
                        await MainActor.run {
                            moving = false
                            problem = failure
                            inICloud = UserDefaults.standard.bool(forKey: PluckkFiles.iCloudKey)
                        }
                    }
                }))
                .disabled(moving)
            Text(moving ? "Copying files…" : problem ?? (inICloud ? "In iCloud Drive › Pluckk, shared with your other Macs." : "On this Mac only, in Application Support › Pluckk."))
                .font(.caption)
                .foregroundColor(problem == nil ? .secondary : .red)
        }
    }
}
