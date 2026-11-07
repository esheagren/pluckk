import SwiftUI
import UniformTypeIdentifiers

/// One card, open under the deck's grid in Statistics, to edit fully: how it's answered (recall,
/// typed blanks, a number), question, answer and context, its image, and its modules with live
/// previews; plus flag, move, practise, delete and a line to the assistant.
struct CardEditorPane: View {
    let cardId: String
    let decks: [DeckSummary]
    /// Saved: the grid's tile takes the new text and tags.
    let onSaved: (_ question: String, _ answer: String, _ tags: [String], _ imageURL: String?) -> Void
    /// Moved to another deck or deleted: it leaves this deck's grid.
    let onRemoved: () -> Void
    let onClose: () -> Void

    enum Kind: String, CaseIterable { case recall = "Recall", typed = "Type blanks", written = "Write it", number = "Number" }

    @State private var loaded = false
    @State private var kind = Kind.recall
    @State private var question = ""
    @State private var fact = ""
    @State private var context = ""
    @State private var blankWords: Set<Int> = []
    @State private var numberText = ""
    @State private var unit = ""
    @State private var tags: [String] = []
    @State private var folderId: String?
    @State private var imageURL: String?
    @State private var modules: [EditableModule] = []
    @State private var catalogue: [[String: Any]] = []
    @State private var userModuleBase: String?
    @State private var original = ""
    @State private var saving = false
    @State private var notice: String?
    @State private var confirmingDelete = false
    @State private var ask = ""
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
            if loaded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let notice { Text(notice).font(.system(size: 12)).foregroundColor(PluckkTheme.Dark.warning) }
                        answerKind
                        texts
                        imageSection
                        moduleSection(.prompt, "With the question", "Shown with the question: a map, audio, an image, a diagram.")
                        moduleSection(.respond, "Answered by", "One module the card is answered in, such as a click on a map. Its score suggests the rating.")
                        moduleSection(.reveal, "With the answer", "Shown once the answer is revealed: audio, a simulation, a worked example.")
                        assistantLine
                    }
                    .padding(18)
                }
                .scrollIndicators(.hidden)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: cardId) { await load() }
    }

    // MARK: Toolbar

    private var dirty: Bool { loaded && snapshot != original }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text("Card").font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
            CardIconButton(systemName: "play.fill", help: "Practise this card now (schedule unchanged)") {
                practiseRun(.init(title: DeckBrowserPanel.short(question), cardIds: [cardId]))
            }
            let marked = tags.contains(Rework.tag)
            CardIconButton(systemName: marked ? "flag.fill" : "flag", help: marked ? "Marked for rework (click to unmark)" : "Mark for rework",
                           hoverTint: PluckkTheme.Dark.warning, tint: marked ? PluckkTheme.Dark.warning : nil) {
                tags = Rework.toggled(tags)
            }
            Menu {
                ForEach(decks.filter { $0.folder_id != folderId }) { d in Button(d.title) { move(to: d.folder_id) } }
            } label: { Image(systemName: "folder").font(.system(size: 12)) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Move to another deck")
            if confirmingDelete {
                Text("Delete?").font(.system(size: 11)).foregroundColor(.secondary)
                Button("Cancel") { confirmingDelete = false }.buttonStyle(.plain).font(.system(size: 11)).foregroundColor(.secondary)
                Button("Delete") { delete() }.buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundColor(Color(hex: "e5534b"))
            } else {
                CardIconButton(systemName: "trash", help: "Delete card", hoverTint: Color(hex: "e5534b")) { confirmingDelete = true }
            }
            Spacer()
            if dirty {
                Button("Revert") { Task { await load() } }.buttonStyle(.plain).font(.system(size: 12)).foregroundColor(.secondary)
            }
            Button(action: save) {
                HStack(spacing: 5) { Text(saving ? "Saving…" : "Save"); Text("⌘↩").font(.system(size: 10)).opacity(0.6) }
            }
            .buttonStyle(PillButtonStyle(prominent: dirty))
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!dirty || saving)
            CardIconButton(systemName: "xmark", help: "Close") { onClose() }
        }
        .padding(.horizontal, 18).padding(.vertical, 8)
    }

    // MARK: How it's answered

    private var answerKind: some View {
        HStack(spacing: 10) {
            Text("Answered by").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
            Picker("", selection: $kind) { ForEach(Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 400)
            Text(kindHelp).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(2)
        }
        .onChange(of: kind) { new in
            if new == .typed && blankWords.isEmpty { seedBlanksFromFact() }
        }
    }

    private var kindHelp: String {
        switch kind {
        case .recall: return "Recall it, reveal, rate yourself."
        case .typed: return "Click words in the question to make them blanks to type."
        case .written: return "Write the whole answer out; Claude checks it against this one."
        case .number: return "Answer with a 95% range around the number."
        }
    }

    @ViewBuilder private var texts: some View {
        CardTextField(label: kind == .typed ? "Question (the full sentence)" : "Question", text: $question, prominent: true, minLines: 2)
        if kind == .typed {
            VStack(alignment: .leading, spacing: 6) {
                Text("BLANKS").font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundColor(.secondary)
                FlowLayout(spacing: 4) {
                    ForEach(Array(words.enumerated()), id: \.offset) { i, w in
                        Text(w)
                            .font(.system(size: 13))
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 5).fill(blankWords.contains(i) ? PluckkTheme.accent.opacity(0.3) : Color.primary.opacity(0.05)))
                            .onTapGesture { if blankWords.contains(i) { blankWords.remove(i) } else { blankWords.insert(i) } }
                    }
                }
                Text(blankWords.isEmpty ? "Click the words to hide." : "Practice shows: \(typedQuestion)")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                if !blankWords.isEmpty {
                    Text("Answers, in order: \(typedAnswers.joined(separator: ", ")). Add “ / other” to a word in the answer below to accept an alternative.")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
        } else {
            CardTextField(label: kind == .number ? "Answer (as shown)" : "Answer", text: $fact, minLines: 2)
        }
        if kind == .number {
            HStack(spacing: 8) {
                TextField("Number", text: $numberText).textFieldStyle(.roundedBorder).frame(width: 140)
                TextField("Unit (e.g. %, km, Mt)", text: $unit).textFieldStyle(.roundedBorder).frame(width: 160)
            }
        }
        CardTextField(label: "Context (shown after the answer; markdown links work)", text: $context, minLines: 2)
    }

    /// The question's words, for picking blanks.
    private var words: [String] { question.split(whereSeparator: { $0.isWhitespace }).map(String.init) }

    /// Consecutive picked words make one blank.
    private var blankGroups: [[Int]] {
        var groups: [[Int]] = []
        for i in blankWords.sorted() {
            if let last = groups.last?.last, last == i - 1 { groups[groups.count - 1].append(i) } else { groups.append([i]) }
        }
        return groups
    }

    private var typedQuestion: String {
        let w = words
        var out: [String] = []
        var i = 0
        while i < w.count {
            if blankWords.contains(i) {
                // keep punctuation stuck to the last word of the blank ("markets." → "___.")
                var j = i
                while blankWords.contains(j + 1) { j += 1 }
                let trailing = String(w[j].reversed().prefix { !$0.isLetter && !$0.isNumber }.reversed())
                out.append("___" + trailing)
                i = j + 1
            } else { out.append(w[i]); i += 1 }
        }
        return out.joined(separator: " ")
    }

    private var typedAnswers: [String] {
        let w = words
        return blankGroups.map { g in
            g.map { w[$0] }.joined(separator: " ").trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
        }
    }

    /// A card already typed (question with ___, answer with the blanks) opens with its sentence
    /// filled back in and those words picked.
    private func seedBlanksFromFact() {
        guard let expected = TypedBlanks.expected(question: question, answer: fact) else { return }
        var filled = question
        var picked: Set<Int> = []
        for answer in expected {
            guard let r = filled.range(of: #"_{2,}"#, options: .regularExpression) else { break }
            let before = filled[..<r.lowerBound].split(whereSeparator: { $0.isWhitespace }).count
            let shown = answer.components(separatedBy: "/").first?.trimmingCharacters(in: .whitespaces) ?? answer
            let n = shown.split(whereSeparator: { $0.isWhitespace }).count
            filled.replaceSubrange(r, with: shown)
            for k in 0..<max(1, n) { picked.insert(before + k) }
        }
        question = filled
        blankWords = picked
    }

    // MARK: Image

    private var imageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("IMAGE").font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundColor(.secondary)
            HStack(alignment: .top, spacing: 12) {
                if let imageURL, let url = URL(string: imageURL) {
                    AsyncImage(url: url) { $0.resizable().aspectRatio(contentMode: .fit) } placeholder: { ProgressView().controlSize(.small) }
                        .frame(maxWidth: 220, maxHeight: 140)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Button(imageURL == nil ? "Paste image" : "Replace from clipboard") { pasteImage() }
                            .buttonStyle(PillButtonStyle(prominent: false))
                        Button("Choose…") { chooseImage() }.buttonStyle(PillButtonStyle(prominent: false))
                        if imageURL != nil {
                            Button("Remove") { removeImage() }.buttonStyle(.plain).font(.system(size: 12)).foregroundColor(Color(hex: "e5534b"))
                        }
                    }
                    if imageURL != nil {
                        Toggle("Show it with the question", isOn: Binding(
                            get: { tags.contains(ImageSide.questionTag) },
                            set: { on in tags = tags.filter { $0 != ImageSide.questionTag } + (on ? [ImageSide.questionTag] : []) }))
                            .font(.system(size: 12))
                    }
                }
            }
        }
    }

    private func pasteImage() {
        guard let image = NSImage(pasteboard: NSPasteboard.general) else { notice = "There's no image on the clipboard."; return }
        upload(image)
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else { return }
        upload(image)
    }

    private func upload(_ image: NSImage) {
        guard let token = AuthManager.shared.accessToken, let data = cardImageJPEG(image) else { return }
        notice = nil
        Task {
            do {
                let stored = try await PluckkAPI.shared.uploadCardImage(token: token, cardId: cardId, imageData: data, mimeType: "image/jpeg")
                let url = "\(stored)?v=\(Int(Date().timeIntervalSince1970))"
                try await PluckkAPI.shared.setCardImage(token: token, cardId: cardId, url: url)
                imageURL = url
                PracticeSession.shared.applyExternalImage(cardId: cardId, url: url)
                onSaved(question, storedAnswer, tags, url)
            } catch { notice = "Couldn't upload the image: \(error.localizedDescription)" }
        }
    }

    private func removeImage() {
        guard let token = AuthManager.shared.accessToken else { return }
        Task {
            do {
                try await PluckkAPI.shared.setCardImage(token: token, cardId: cardId, url: nil)
                imageURL = nil
                tags = tags.filter { $0 != ImageSide.questionTag }
            } catch { notice = "Couldn't remove the image: \(error.localizedDescription)" }
        }
    }

    // MARK: Modules

    struct EditableModule: Identifiable, Equatable {
        let id = UUID()
        var slot: ModuleSlot
        var use: String
        var propsText: String
    }

    private func moduleSection(_ slot: ModuleSlot, _ title: String, _ help: String) -> some View {
        let here = modules.filter { $0.slot == slot }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundColor(.secondary)
                    .help(help)
                Spacer()
                if slot != .respond || here.isEmpty {
                    Menu {
                        let fits = catalogue.filter { (($0["slots"] as? [String]) ?? []).contains(slot.rawValue) }
                        if fits.isEmpty { Text("No modules fit here yet") }
                        ForEach(Array(fits.enumerated()), id: \.offset) { _, m in
                            Button(moduleName(m)) { add(m, to: slot) }
                        }
                    } label: { Label("Add", systemImage: "plus").font(.system(size: 11)) }
                        .menuStyle(.borderlessButton).fixedSize()
                        .help("Add a module " + title.lowercased())
                }
            }
            ForEach(here) { m in moduleEditor(m) }
        }
    }

    private func moduleName(_ m: [String: Any]) -> String {
        let use = m["use"] as? String ?? (m["slug"] as? String).map { "me/\($0)" } ?? "?"
        let describe = (m["describe"] as? String ?? "").prefix(60)
        return describe.isEmpty ? use : "\(use) — \(describe)…"
    }

    private func add(_ m: [String: Any], to slot: ModuleSlot) {
        guard let use = m["use"] as? String else { notice = "Publish that module before putting it on a card."; return }
        let samples = m["samples"] as? [[String: Any]] ?? []
        let sample = samples.first { $0["slot"] as? String == slot.rawValue } ?? samples.first
        let props = sample?["props"] ?? [String: Any]()
        let text = (try? JSONSerialization.data(withJSONObject: props, options: [.prettyPrinted, .sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        modules.append(EditableModule(slot: slot, use: use, propsText: text))
    }

    private func moduleEditor(_ m: EditableModule) -> some View {
        let index = modules.firstIndex { $0.id == m.id }
        let props = parse(m.propsText)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(m.use).font(.system(size: 12, weight: .semibold).monospaced())
                if props == nil { Text("props aren't valid JSON").font(.system(size: 11)).foregroundColor(PluckkTheme.Dark.warning) }
                Spacer()
                Button(action: { modules.removeAll { $0.id == m.id } }) { Image(systemName: "trash").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundColor(.secondary).help("Remove this module")
            }
            HStack(alignment: .top, spacing: 10) {
                TextEditor(text: Binding(get: { index.map { modules[$0].propsText } ?? "" },
                                         set: { if let i = index { modules[i].propsText = $0 } }))
                    .font(.system(size: 11).monospaced())
                    .frame(minWidth: 200, maxWidth: 280, minHeight: 90, maxHeight: 220)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                ModulePreviewDebounced(use: m.use, propsText: m.propsText, slot: m.slot, src: source(for: m.use))
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.03)))
    }

    private func parse(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    private func source(for use: String) -> String? {
        let parts = use.split(separator: "@")
        guard parts.count == 2 else { return nil }
        if parts[0].hasPrefix("me/"), let base = userModuleBase { return "\(base)/\(parts[0].dropFirst(3))/\(parts[1])/index.html" }
        return "/modules/\(parts[0])/\(parts[1])/index.html"
    }

    // MARK: Assistant

    private var assistantLine: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundColor(PluckkTheme.accent).font(.system(size: 12))
            TextField("Ask the assistant to change this card (e.g. “make it type-it with blanks for the three causes”)", text: $ask)
                .textFieldStyle(.plain).font(.system(size: 12))
                .onSubmit(sendToAssistant)
            Button("Ask", action: sendToAssistant).buttonStyle(PillButtonStyle(prominent: false)).disabled(ask.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }

    private func sendToAssistant() {
        let text = ask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if PluckkPanel.shared?.isAssistantOpen == false { PluckkPanel.shared?.toggleAssistant() }
        AssistantSession.shared.send("About card \(cardId) (open in the Statistics editor): \(text)")
        ask = ""
        notice = "Sent to the assistant. Revert here to load its changes once it's done."
    }

    // MARK: Loading and saving

    /// Everything the Save button would send, to tell whether anything changed.
    private var snapshot: String {
        "\(kind)|\(question)|\(fact)|\(context)|\(blankWords.sorted())|\(numberText)|\(unit)|\(tags)|\(modules.map { "\($0.slot)\($0.use)\($0.propsText)" })"
    }

    private var storedAnswer: String {
        let first = kind == .typed ? typedAnswers.joined(separator: ", ") : fact.trimmingCharacters(in: .whitespacesAndNewlines)
        let more = context.trimmingCharacters(in: .whitespacesAndNewlines)
        return more.isEmpty ? first : "\(first)\n\n\(more)"
    }

    private func load() async {
        guard let token = AuthManager.shared.accessToken else { return }
        loaded = false
        notice = nil
        confirmingDelete = false
        do {
            let data = try await PluckkAPI.shared.raw(token: token, method: "GET", path: "/api/v1/cards/\(cardId)", json: nil)
            guard let card = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            question = card["question"] as? String ?? ""
            let answer = card["answer"] as? String ?? ""
            let parts = answer.components(separatedBy: "\n\n")
            fact = parts.first ?? ""
            context = parts.dropFirst().joined(separator: "\n\n")
            tags = card["tags"] as? [String] ?? []
            folderId = card["folder_id"] as? String
            imageURL = card["image_url"] as? String
            let isNumber = (card["answer_type"] as? String) == "numeric"
            numberText = (card["numeric_answer"] as? Double).map { NumberText.format($0) } ?? ""
            unit = card["numeric_unit"] as? String ?? ""
            blankWords = []
            let writtenMode = ((card["spec"] as? [String: Any])?["answer_type"] as? String) == "written"
            kind = isNumber ? .number : writtenMode ? .written : TypedBlanks.expected(question: question, answer: answer) != nil ? .typed : .recall
            if kind == .typed { seedBlanksFromFact() }
            modules = []
            if let m = (card["spec"] as? [String: Any])?["modules"] as? [String: Any] {
                func rows(_ value: Any?, _ slot: ModuleSlot) -> [EditableModule] {
                    let list = (value as? [[String: Any]]) ?? ((value as? [String: Any]).map { [$0] } ?? [])
                    return list.compactMap { u in
                        guard let use = u["use"] as? String else { return nil }
                        let props = u["props"] ?? [String: Any]()
                        let text = (try? JSONSerialization.data(withJSONObject: props, options: [.prettyPrinted, .sortedKeys]))
                            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                        return EditableModule(slot: slot, use: use, propsText: text)
                    }
                }
                modules = rows(m["prompt"], .prompt) + rows(m["respond"], .respond) + rows(m["reveal"], .reveal)
            }
            if catalogue.isEmpty,
               let listed = try? JSONSerialization.jsonObject(with: try await PluckkAPI.shared.raw(token: token, method: "GET", path: "/api/v1/modules", json: nil)) as? [String: Any] {
                catalogue = listed["modules"] as? [[String: Any]] ?? []
                userModuleBase = listed["user_module_base"] as? String
            }
            loaded = true
            original = snapshot
        } catch {
            notice = "Couldn't open the card: \(error.localizedDescription)"
            loaded = true
        }
    }

    private func save() {
        guard let token = AuthManager.shared.accessToken else { return }
        let q = kind == .typed ? typedQuestion : question.trimmingCharacters(in: .whitespacesAndNewlines)
        let a = storedAnswer
        guard !q.isEmpty, !a.isEmpty else { notice = "A card needs a question and an answer."; return }
        if kind == .typed && blankWords.isEmpty { notice = "Pick at least one word to blank, or choose Recall."; return }
        var body: [String: Any] = ["question": q, "answer": a, "tags": tags]
        if kind == .number {
            guard let value = NumberText.parse(numberText) else { notice = "That number didn't read as a number."; return }
            body["answer_type"] = "numeric"
            body["numeric_answer"] = value
            body["numeric_unit"] = unit.isEmpty ? NSNull() : unit
        } else {
            body["answer_type"] = kind == .written ? "written" : "text"
        }
        var slots: [String: Any] = [:]
        for slot in [ModuleSlot.prompt, .respond, .reveal] {
            let here = modules.filter { $0.slot == slot }
            var uses: [[String: Any]] = []
            for m in here {
                guard let props = parse(m.propsText) else { notice = "\(m.use)'s props aren't valid JSON."; return }
                uses.append(["use": m.use, "props": props])
            }
            if slot == .respond { if let first = uses.first { slots["respond"] = first } } else if !uses.isEmpty { slots[slot.rawValue] = uses }
        }
        body["modules"] = slots.isEmpty ? NSNull() : slots
        saving = true
        notice = nil
        Task {
            defer { saving = false }
            do {
                _ = try await PluckkAPI.shared.raw(token: token, method: "PATCH", path: "/api/v1/cards/\(cardId)", json: body)
                PracticeSession.shared.applyExternalEdit(cardId: cardId, question: q, answer: a)
                PracticeSession.shared.applyExternalTags(cardId: cardId, tags: tags)
                onSaved(q, a, tags, imageURL)
                await load()
            } catch {
                notice = "Couldn't save: \(error.localizedDescription)"
            }
        }
    }

    private func move(to folder: String?) {
        guard let token = AuthManager.shared.accessToken else { return }
        Task {
            do {
                try await PluckkAPI.shared.moveCard(token: token, cardId: cardId, folderId: folder)
                onRemoved()
            } catch { notice = "Couldn't move: \(error.localizedDescription)" }
        }
    }

    private func delete() {
        guard let token = AuthManager.shared.accessToken else { return }
        Task {
            do {
                _ = try await PluckkAPI.shared.deleteCard(token: token, cardId: cardId)
                PracticeSession.shared.removeCardExternally(cardId)
                onRemoved()
            } catch { notice = "Couldn't delete: \(error.localizedDescription)" }
        }
    }
}

/// A module's live preview that redraws a moment after its props stop changing, and only when
/// they're valid JSON.
private struct ModulePreviewDebounced: View {
    let use: String
    let propsText: String
    let slot: ModuleSlot
    let src: String?
    @State private var shown: String?

    var body: some View {
        Group {
            if let shown, let data = shown.data(using: .utf8), let props = try? JSONDecoder().decode(JSONValue.self, from: data) {
                ModulePreview(module: ModuleUse(use: use, props: props, src: src), slot: slot, title: "Preview")
                    .id(shown)
            } else {
                Text("Preview appears when the props are valid JSON.").font(.system(size: 11)).foregroundColor(.secondary)
            }
        }
        .task(id: propsText) {
            try? await Task.sleep(nanoseconds: 700_000_000)
            if (try? JSONSerialization.jsonObject(with: Data(propsText.utf8))) != nil { shown = propsText }
        }
    }
}
