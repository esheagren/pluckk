import SwiftUI

/// The Modules page: every module (built in, or his own), how many cards use each, and for the one
/// picked, what it does, a live sample, the cards that use it (any of which opens in the editor
/// below), and a line to the assistant, which can change the module, make his own version, or
/// find cards that would be better with it. Cards that share a module share an idea; this is where
/// that shows.
struct ModulesView: View {
    @ObservedObject private var appState = AppState.shared
    @State private var modules: [[String: Any]] = []
    @State private var usage: [String: [[String: Any]]] = [:]
    @State private var userModuleBase: String?
    @State private var openCard: String?
    @State private var ask = ""
    @State private var problem: String?

    private func use(_ m: [String: Any]) -> String { m["use"] as? String ?? "me/\(m["slug"] as? String ?? "?")@draft" }

    private var chosen: [String: Any]? {
        appState.openModuleUse.flatMap { u in modules.first { use($0) == u } } ?? modules.first
    }

    var body: some View {
        HStack(spacing: 0) {
            list
                .frame(width: 230)
            Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1)
            if let m = chosen { detail(m) } else { Spacer() }
        }
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .pluckkCardChanged)) { _ in Task { await load() } }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Text("MODULES").font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundColor(.secondary)
                    .padding(.horizontal, 10).padding(.bottom, 6)
                ForEach(Array(modules.enumerated()), id: \.offset) { _, m in
                    let u = use(m)
                    let on = chosen.map(use) == u
                    Button(action: { appState.openModuleUse = u; openCard = nil }) {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(ModuleNames.title(m, respond: false)).font(.system(size: 13, weight: on ? .semibold : .regular)).lineLimit(1)
                                Text(m["owner"] as? String == "mine" ? "yours · \(u)" : u).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            Text("\(usage[u]?.count ?? 0)").font(.system(size: 11).monospacedDigit()).foregroundColor(.secondary)
                                .help("Cards using it")
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.primary.opacity(0.08) : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if let problem { Text(problem).font(.system(size: 11)).foregroundColor(.secondary).padding(10) }
                Button(action: { ask = "Build a new module: " }) {
                    Label("New module…", systemImage: "plus").font(.system(size: 12))
                }
                .buttonStyle(.plain).foregroundColor(.secondary).padding(10)
            }
            .padding(.vertical, 14).padding(.horizontal, 8)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder private func detail(_ m: [String: Any]) -> some View {
        let u = use(m)
        let cards = usage[u] ?? []
        let slots = (m["slots"] as? [String]) ?? []
        let sample = (m["samples"] as? [[String: Any]])?.first
        GeometryReader { geo in
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(ModuleNames.title(m, respond: false)).font(.system(size: 17, weight: .semibold))
                            Text(u).font(.system(size: 11).monospaced()).foregroundColor(.secondary)
                            Spacer()
                            Text(m["owner"] as? String == "mine" ? "Yours" : "Built in")
                                .font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                                .padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().fill(Color.primary.opacity(0.07)))
                        }
                        if let d = m["describe"] as? String { Text(d).font(.system(size: 12)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true) }
                        Text("Fits: " + slots.map { $0 == "prompt" ? "with the question" : $0 == "respond" ? "as the answer" : "with the answer" }.joined(separator: ", "))
                            .font(.system(size: 11)).foregroundColor(.secondary)
                        if let sample, let slotName = sample["slot"] as? String, let slot = ModuleSlot(rawValue: slotName),
                           let data = try? JSONSerialization.data(withJSONObject: sample["props"] ?? [:]),
                           let props = try? JSONDecoder().decode(JSONValue.self, from: data), m["use"] is String {
                            ModulePreview(module: ModuleUse(use: u, props: props, src: ModuleNames.source(for: u, userBase: userModuleBase)),
                                          slot: slot, title: "Sample")
                                .frame(maxWidth: 640)
                                .id(u)
                        }
                        assistantLine(m)
                        Text("CARDS USING IT (\(cards.count))").font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundColor(.secondary)
                        if cards.isEmpty {
                            Text("No cards yet. Ask the assistant to find cards that would be better with it.").font(.system(size: 12)).foregroundColor(.secondary)
                        }
                        ForEach(Array(cards.enumerated()), id: \.offset) { _, c in
                            let id = c["id"] as? String ?? ""
                            Button(action: { openCard = id }) {
                                HStack(spacing: 8) {
                                    Text(c["question"] as? String ?? "").font(.system(size: 12)).lineLimit(1)
                                    Spacer()
                                    Text((c["deck"] as? String) ?? "Unfiled").font(.system(size: 10)).foregroundColor(.secondary)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 6).fill(openCard == id ? PluckkTheme.accent.opacity(0.12) : Color.primary.opacity(0.03)))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(18)
                }
                .scrollIndicators(.hidden)
                .frame(height: openCard == nil ? geo.size.height : max(200, geo.size.height * 0.42))
                if let id = openCard {
                    Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
                    CardEditorPane(cardId: id, onRemoved: { openCard = nil; Task { await load() } }, onClose: { openCard = nil })
                        .id(id)
                }
            }
        }
    }

    private func assistantLine(_ m: [String: Any]) -> some View {
        let mine = m["owner"] as? String == "mine"
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundColor(PluckkTheme.accent).font(.system(size: 12))
                TextField(mine ? "Ask the assistant to change this module, e.g. “let the map zoom”" : "Ask the assistant about this module, e.g. “make my own version that…”", text: $ask)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .onSubmit(send)
                Button("Ask", action: send).buttonStyle(PillButtonStyle(prominent: false)).disabled(ask.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
            HStack(spacing: 12) {
                Button("Find cards that would be better with it") {
                    ask = "Look through my cards for ones that would teach better with \(use(m)), propose them as a table, and attach it once I agree."
                    send()
                }
                if !mine {
                    Button("Make my own version") { ask = "Make my own version of \(use(m)) that "; }
                }
            }
            .buttonStyle(.plain).font(.system(size: 11)).foregroundColor(.secondary)
        }
        .frame(maxWidth: 640)
    }

    private func send() {
        let text = ask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if PluckkPanel.shared?.isAssistantOpen == false { PluckkPanel.shared?.toggleAssistant() }
        AssistantSession.shared.send(text)
        ask = ""
    }

    private func load() async {
        guard let token = AuthManager.shared.accessToken else { return }
        do {
            let listed = try JSONSerialization.jsonObject(with: try await PluckkAPI.shared.raw(token: token, method: "GET", path: "/api/v1/modules", json: nil)) as? [String: Any]
            modules = listed?["modules"] as? [[String: Any]] ?? []
            userModuleBase = listed?["user_module_base"] as? String
            let used = try JSONSerialization.jsonObject(with: try await PluckkAPI.shared.raw(token: token, method: "GET", path: "/api/v1/modules/usage", json: nil)) as? [String: Any]
            usage = used?["usage"] as? [String: [[String: Any]]] ?? [:]
            // Most-used first, so the modules that tie the most cards together lead.
            modules.sort { (usage[use($0)]?.count ?? 0) > (usage[use($1)]?.count ?? 0) }
        } catch {
            problem = "Couldn't load the modules."
        }
    }
}
