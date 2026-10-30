import SwiftUI

/// The chat panel on the right of the card.
struct AssistantView: View {
    @ObservedObject private var session = AssistantSession.shared
    @ObservedObject private var appState = AppState.shared
    @State private var draft = ""
    @FocusState private var inputFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool { colorScheme == .dark }
    private var rule: Color { isDark ? PluckkTheme.Dark.cardBorder : PluckkTheme.Light.cardBorder }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(rule).frame(height: 1)
            transcript
            if let approval = session.pendingApproval { approvalCard(approval) }
            input
        }
        .onAppear {
            // Only when opened with the button: if it's just still open, Practice keeps the keys.
            if session.wantsFocus { inputFocused = true }
            session.wantsFocus = false
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Assistant").font(.system(size: 12, weight: .semibold))
            Text(session.modelName).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
            Spacer()
            Button(action: { session.newChat() }) {
                Image(systemName: "square.and.pencil").font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help("New chat")
            .disabled(session.items.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if session.items.isEmpty { emptyState }
                    ForEach(session.items) { row($0).id($0.id) }
                    if session.busy && session.pendingApproval == nil {
                        ProgressView().controlSize(.small).id("working")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
            }
            .scrollIndicators(.hidden)
            .onChange(of: session.items.last?.text) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: session.items.count) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if let problem = session.setupProblem {
            VStack(alignment: .leading, spacing: 10) {
                Text(problem).font(.system(size: 13)).foregroundColor(.secondary)
                Button("Open Settings") { appState.currentView = .settings }
                    .buttonStyle(PillButtonStyle(prominent: true))
            }
        } else {
            Text("Ask about the card you're on, or have it fix cards and make new ones.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private func row(_ item: AssistantItem) -> some View {
        switch item.kind {
        case .user:
            HStack {
                Spacer(minLength: 28)
                Text(item.text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(PluckkTheme.accent.opacity(0.16)))
            }
        case .assistant:
            Text(cardMarkdown(item.text))
                .font(.system(size: 13))
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .tool:
            Text(item.text)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(2)
        case .notice:
            Text(item.text)
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "e5a14b"))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func approvalCard(_ approval: AssistantApproval) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(approval.title).font(.system(size: 12, weight: .semibold))
            ScrollView {
                Text(approval.detail)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 150)
            HStack(spacing: 8) {
                Spacer()
                Button("Don't") { session.resolveApproval(false) }.buttonStyle(PillButtonStyle(prominent: false))
                Button("Allow") { session.resolveApproval(true) }.buttonStyle(PillButtonStyle(prominent: true))
            }
        }
        .padding(12)
        .background(isDark ? PluckkTheme.Dark.card : PluckkTheme.Light.card)
        .overlay(alignment: .top) { Rectangle().fill(rule).frame(height: 1) }
    }

    private var input: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask about this card…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...6)
                .focused($inputFocused)
                .onSubmit(send)
                .onExitCommand { inputFocused = false }
            Button(action: { session.busy ? session.stop() : send() }) {
                Image(systemName: session.busy ? "stop.fill" : "arrow.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Color(hex: "1a1a1a"))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(PluckkTheme.accent))
            }
            .buttonStyle(.plain)
            .disabled(!session.busy && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help(session.busy ? "Stop" : "Send")
        }
        .padding(10)
        .overlay(alignment: .top) { Rectangle().fill(rule).frame(height: 1) }
    }

    private func send() {
        guard !session.busy, session.setupProblem == nil else { return }
        session.send(draft)
        draft = ""
        inputFocused = true
    }
}

/// Settings → Assistant: which model it uses, its key, its system prompt and its folders.
struct AssistantSettingsSection: View {
    @State private var preset = AssistantSettings.preset
    @State private var apiKey = ""
    @State private var model = ""
    @State private var baseURL = ""
    @State private var prompt = AssistantSettings.systemPrompt
    @State private var folders = AssistantSettings.foldersText

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Assistant").font(.headline)

            Picker("Provider", selection: $preset) {
                ForEach(AssistantPreset.allCases) { Text($0.title).tag($0) }
            }
            .onChange(of: preset) { value in
                AssistantSettings.preset = value
                load()
            }

            if preset.needsKey {
                labelled("API key") {
                    SecureField("Paste your key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: apiKey) { AssistantSettings.setAPIKey($0, preset) }
                }
            }
            labelled("Model") {
                TextField("Model name", text: $model)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: model) { AssistantSettings.setModel($0, preset) }
            }
            if preset != .claude {
                labelled("Provider URL") {
                    TextField("https://…/v1", text: $baseURL)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: baseURL) { AssistantSettings.setBaseURL($0, preset) }
                }
            }
            labelled("Folders it can read and write (one per line)") {
                editor($folders, height: 56, monospaced: true)
                    .onChange(of: folders) { AssistantSettings.foldersText = $0 }
            }
            labelled("System prompt") {
                editor($prompt, height: 180, monospaced: false)
                    .onChange(of: prompt) { AssistantSettings.systemPrompt = $0 }
                Button("Reset to default") { prompt = AssistantSettings.defaultSystemPrompt }
                    .buttonStyle(.plain).font(.caption).foregroundColor(.secondary)
            }
            Text("Your API key stays on this Mac and is sent only to the provider above. Usage is billed by that provider, separately from any Claude subscription.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .onAppear(perform: load)
    }

    private func load() {
        apiKey = AssistantSettings.apiKey(preset)
        model = AssistantSettings.model(preset)
        baseURL = AssistantSettings.baseURL(preset)
    }

    private func labelled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundColor(.secondary)
            content()
        }
    }

    private func editor(_ text: Binding<String>, height: CGFloat, monospaced: Bool) -> some View {
        TextEditor(text: text)
            .font(.system(size: 12, design: monospaced ? .monospaced : .default))
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}
