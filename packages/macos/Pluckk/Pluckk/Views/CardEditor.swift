import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    /// A card changed outside the editor (the assistant, mostly); object is the card id.
    static let pluckkCardChanged = Notification.Name("PluckkCardChanged")
}

/// The one card editor, used on the Decks page and in Practice. How a card is answered is a short
/// tree: recall it, answer in words (type the blanks, or write it out), give a number, or answer
/// in something interactive (a map click, and whatever modules come next). Extras such as an
/// image, audio or a map ride along with the question or the answer. Module settings appear as a
/// plain form; their raw props stay behind Advanced. The assistant sees which card is open here
/// and its changes reload into it.
struct CardEditorPane: View {
    let cardId: String
    var decks: [DeckSummary] = []
    /// Saved: callers update their copy of the card.
    var onSaved: (_ question: String, _ answer: String, _ tags: [String], _ imageURL: String?) -> Void = { _, _, _, _ in }
    /// Moved to another deck (or deleted, when there's no onDeleted).
    var onRemoved: () -> Void = {}
    /// Deleted: the caller drops it and offers Undo with the event id.
    var onDeleted: ((String?) -> Void)? = nil
    /// Replaces the editor's own delete (Practice deletes through its queue, with ← to undo).
    var deleteOverride: (() -> Void)? = nil
    let onClose: () -> Void

    enum Top: String, CaseIterable { case recall = "Recall", words = "Words", number = "Number", interactive = "Interactive" }
    enum WordsMode: String, CaseIterable { case blanks = "Type the blanks", written = "Write it out" }

    @State private var loaded = false
    @State private var top = Top.recall
    @State private var wordsMode = WordsMode.blanks
    @State private var question = ""
    @State private var fact = ""
    @State private var context = ""
    @State private var blankWords: Set<Int> = []
    @State private var numberText = ""
    @State private var unit = ""
    @State private var tags: [String] = []
    @State private var folderId: String?
    @State private var provenance: [String: Any]?
    @State private var imageURL: String?
    @State private var respond: EditableModule?
    @State private var extras: [EditableModule] = []
    @State private var splits: [SplitDraft] = []
    @State private var catalogue: [[String: Any]] = []
    @State private var userModuleBase: String?
    @State private var allDecks: [DeckSummary] = []
    @State private var original = ""
    @State private var saving = false
    @State private var notice: String?
    @State private var changedElsewhere = false
    @State private var confirmingDelete = false
    @State private var ask = ""

    struct EditableModule: Identifiable, Equatable {
        let id = UUID()
        var slot: ModuleSlot
        var use: String
        var propsText: String
    }

    struct SplitDraft: Identifiable { let id = UUID(); var question = ""; var answer = "" }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
            if loaded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if changedElsewhere {
                            HStack(spacing: 8) {
                                Text("The assistant changed this card.").font(.system(size: 12))
                                Button("Load its version") { Task { await load() } }.buttonStyle(PillButtonStyle(prominent: true))
                                Button("Keep mine") { changedElsewhere = false }.buttonStyle(.plain).font(.system(size: 12)).foregroundColor(.secondary)
                            }
                        }
                        if let notice { Text(notice).font(.system(size: 12)).foregroundColor(PluckkTheme.Dark.warning) }
                        answering
                        texts
                        extrasSection
                        splitSection
                        assistantLine
                    }
                    .padding(18)
                }
                .scrollIndicators(.hidden)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .task(id: cardId) { await load() }
        .onAppear { AppState.shared.editingCardId = cardId }
        .onChange(of: cardId) { AppState.shared.editingCardId = $0 }
        .onDisappear { if AppState.shared.editingCardId == cardId { AppState.shared.editingCardId = nil } }
        .onReceive(NotificationCenter.default.publisher(for: .pluckkCardChanged)) { note in
            guard note.object as? String == cardId, !saving else { return }
            if dirty { changedElsewhere = true } else { Task { await load() } }
        }
    }

    // MARK: Toolbar

    private var dirty: Bool { loaded && snapshot != original }
    private var moveTargets: [DeckSummary] { (decks.isEmpty ? allDecks : decks).filter { $0.folder_id != folderId } }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text("Editing").font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
            CardIconButton(systemName: "play.fill", help: "Practise this card now (schedule unchanged)") {
                practiseRun(.init(title: DeckBrowserPanel.short(question), cardIds: [cardId]))
            }
            let marked = tags.contains(Rework.tag)
            CardIconButton(systemName: marked ? "flag.fill" : "flag", help: marked ? "Marked for rework (click to unmark)" : "Mark for rework",
                           hoverTint: PluckkTheme.Dark.warning, tint: marked ? PluckkTheme.Dark.warning : nil) {
                tags = Rework.toggled(tags)
            }
            Menu {
                ForEach(moveTargets) { d in Button(d.title) { move(to: d.folder_id) } }
            } label: { Image(systemName: "folder").font(.system(size: 12)) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Move to another deck")
            CardIconButton(systemName: "plus.square.on.square", help: "Split: add another card made from this one") {
                splits.append(SplitDraft())
            }
            CardIconButton(systemName: "trash", help: "Delete card (Undo follows)", hoverTint: Color(hex: "e5534b")) { delete() }
            Spacer()
            if dirty {
                Button("Revert") { Task { await load() } }.buttonStyle(.plain).font(.system(size: 12)).foregroundColor(.secondary)
            }
            Button(action: save) {
                HStack(spacing: 5) { Text(saving ? "Saving…" : splits.isEmpty ? "Save" : "Save all"); Text("⌘↩").font(.system(size: 10)).opacity(0.6) }
            }
            .buttonStyle(PillButtonStyle(prominent: dirty))
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!dirty || saving)
            CardIconButton(systemName: "xmark", help: "Close the editor") { onClose() }
        }
        .padding(.horizontal, 18).padding(.vertical, 8)
    }

    // MARK: How it's answered

    private var answering: some View {
        VStack(alignment: .leading, spacing: 10) {
            label("How it's answered")
            Picker("", selection: $top) { ForEach(Top.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 420)
            switch top {
            case .recall:
                caption("You recall it, reveal the answer and rate yourself.")
            case .words:
                Picker("", selection: $wordsMode) { ForEach(WordsMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 300)
                caption(wordsMode == .blanks ? "Click words in the question to hide them; you type each one in Practice."
                        : "You write the whole answer; Claude checks which of its ideas you got across.")
            case .number:
                HStack(spacing: 8) {
                    TextField("Number", text: $numberText).textFieldStyle(.roundedBorder).frame(width: 140)
                    TextField("Unit (e.g. %, km, Mt)", text: $unit).textFieldStyle(.roundedBorder).frame(width: 160)
                }
                caption("You give a 95% range; it's scored against this number.")
            case .interactive:
                interactiveChoices
            }
        }
        .onChange(of: top) { new in
            if new == .words && wordsMode == .blanks && blankWords.isEmpty { seedBlanksFromFact() }
        }
    }

    /// The respond-capable modules, by what they ask of you; picking one makes it the answer.
    private var interactiveChoices: some View {
        let fits = catalogue.filter { (($0["slots"] as? [String]) ?? []).contains("respond") && $0["use"] is String }
        return VStack(alignment: .leading, spacing: 10) {
            FlowLayout(spacing: 6) {
                ForEach(Array(fits.enumerated()), id: \.offset) { _, m in
                    let use = m["use"] as? String ?? ""
                    let chosen = respond?.use == use
                    Button(action: { chooseRespond(m) }) {
                        Text(title(of: m, respond: true))
                            .font(.system(size: 12, weight: chosen ? .semibold : .regular))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(chosen ? PluckkTheme.accent.opacity(0.25) : Color.primary.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                    .help(m["describe"] as? String ?? "")
                }
                Button(action: { ask = "Build a new way to answer this card: " }) {
                    Label("Something new…", systemImage: "sparkles").font(.system(size: 12))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().stroke(Color.primary.opacity(0.15)))
                }
                .buttonStyle(.plain)
                .help("Ask the assistant to build a module for this kind of question (anatomy, speaking, code…)")
            }
            if let r = respond { attachmentRow(r, placement: false) }
            else { caption("Pick how you'll answer, e.g. clicking a place on a map. Its score suggests the rating.") }
        }
    }

    private func chooseRespond(_ m: [String: Any]) {
        guard let use = m["use"] as? String, respond?.use != use else { return }
        respond = EditableModule(slot: .respond, use: use, propsText: sampleProps(m, slot: .respond))
    }

    // MARK: Text

    @ViewBuilder private var texts: some View {
        CardTextField(label: isBlanks ? "Question (the full sentence)" : "Question", text: $question, prominent: true, minLines: 2)
        if isBlanks {
            VStack(alignment: .leading, spacing: 6) {
                label("Blanks")
                FlowLayout(spacing: 4) {
                    ForEach(Array(words.enumerated()), id: \.offset) { i, w in
                        Text(w)
                            .font(.system(size: 13))
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 5).fill(blankWords.contains(i) ? PluckkTheme.accent.opacity(0.3) : Color.primary.opacity(0.05)))
                            .onTapGesture { if blankWords.contains(i) { blankWords.remove(i) } else { blankWords.insert(i) } }
                    }
                }
                caption(blankWords.isEmpty ? "Click the words to hide." : "Practice shows: \(typedQuestion)  ·  answers: \(typedAnswers.joined(separator: ", "))")
            }
        } else {
            CardTextField(label: top == .number ? "Answer (as shown)" : "Answer", text: $fact, minLines: 2)
        }
        CardTextField(label: "Context (shown after the answer; markdown links work)", text: $context, minLines: 2)
    }

    private var isBlanks: Bool { top == .words && wordsMode == .blanks }

    private var words: [String] { question.split(whereSeparator: { $0.isWhitespace }).map(String.init) }

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

    // MARK: Extras: image and modules

    private var extrasSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                label("Also on the card")
                Spacer()
                Menu {
                    Button("Image from the clipboard") { pasteImage() }
                    Button("Image from a file…") { chooseImage() }
                    let fits = catalogue.filter { m in
                        let slots = (m["slots"] as? [String]) ?? []
                        return (slots.contains("prompt") || slots.contains("reveal")) && m["use"] is String
                    }
                    if !fits.isEmpty { Divider() }
                    ForEach(Array(fits.enumerated()), id: \.offset) { _, m in
                        Button(title(of: m, respond: false)) { addExtra(m) }
                    }
                    Divider()
                    Button("Something else… (ask the assistant)") { ask = "Add to this card: " }
                } label: { Label("Add", systemImage: "plus").font(.system(size: 12)) }
                    .menuStyle(.borderlessButton).fixedSize()
            }
            if imageURL == nil && extras.isEmpty {
                caption("Nothing yet. Add an image, audio, a map or a simulation to show with the question or the answer.")
            }
            if let url = MediaStore.displayURL(imageURL) { imageRow(url) }
            ForEach(extras) { m in attachmentRow(m, placement: true) }
        }
    }

    private func imageRow(_ url: URL) -> some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: url) { $0.resizable().aspectRatio(contentMode: .fit) } placeholder: { ProgressView().controlSize(.small) }
                .frame(maxWidth: 160, maxHeight: 110)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 6) {
                Text("Image").font(.system(size: 12, weight: .semibold))
                Picker("", selection: Binding(
                    get: { tags.contains(ImageSide.questionTag) },
                    set: { on in tags = tags.filter { $0 != ImageSide.questionTag } + (on ? [ImageSide.questionTag] : []) })) {
                    Text("With the answer").tag(false)
                    Text("With the question").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 260)
                HStack(spacing: 10) {
                    Button("Replace from clipboard") { pasteImage() }.buttonStyle(.plain).font(.system(size: 11)).foregroundColor(.secondary)
                    Button("Remove") { removeImage() }.buttonStyle(.plain).font(.system(size: 11)).foregroundColor(Color(hex: "e5534b"))
                }
            }
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.03)))
    }

    /// One module on the card as a person sees it: what it is, where it shows, its settings as a
    /// form, a live preview. Raw props only under Advanced.
    private func attachmentRow(_ m: EditableModule, placement: Bool) -> some View {
        let manifest = catalogue.first { $0["use"] as? String == m.use }
        let props = parse(m.propsText)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(manifest.map { title(of: $0, respond: m.slot == .respond) } ?? m.use).font(.system(size: 12, weight: .semibold))
                if props == nil { Text("settings need fixing").font(.system(size: 11)).foregroundColor(PluckkTheme.Dark.warning) }
                Spacer()
                if placement, let slots = manifest?["slots"] as? [String], slots.contains("prompt"), slots.contains("reveal") {
                    Picker("", selection: Binding(get: { m.slot }, set: { new in update(m) { $0.slot = new } })) {
                        Text("With the question").tag(ModuleSlot.prompt)
                        Text("With the answer").tag(ModuleSlot.reveal)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 260)
                }
                Button(action: { remove(m) }) { Image(systemName: "trash").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundColor(.secondary).help("Remove")
            }
            HStack(alignment: .top, spacing: 12) {
                ModuleSettingsForm(schema: manifest?["props"] as? [String: Any], propsText: Binding(
                    get: { current(m)?.propsText ?? m.propsText },
                    set: { text in update(m) { $0.propsText = text } }))
                    .frame(minWidth: 220, maxWidth: 300, alignment: .leading)
                ModulePreviewDebounced(use: m.use, propsText: m.propsText, slot: m.slot, src: source(for: m.use))
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.03)))
    }

    private func current(_ m: EditableModule) -> EditableModule? {
        respond?.id == m.id ? respond : extras.first { $0.id == m.id }
    }

    private func update(_ m: EditableModule, _ change: (inout EditableModule) -> Void) {
        if respond?.id == m.id, var r = respond { change(&r); respond = r; return }
        if let i = extras.firstIndex(where: { $0.id == m.id }) { change(&extras[i]) }
    }

    private func remove(_ m: EditableModule) {
        if respond?.id == m.id { respond = nil; return }
        extras.removeAll { $0.id == m.id }
    }

    private func addExtra(_ m: [String: Any]) {
        guard let use = m["use"] as? String else { return }
        let slots = (m["slots"] as? [String]) ?? []
        let slot: ModuleSlot = slots.contains("reveal") ? .reveal : .prompt
        extras.append(EditableModule(slot: slot, use: use, propsText: sampleProps(m, slot: slot)))
    }

    private func sampleProps(_ m: [String: Any], slot: ModuleSlot) -> String {
        let samples = m["samples"] as? [[String: Any]] ?? []
        let sample = samples.first { $0["slot"] as? String == slot.rawValue } ?? samples.first
        let props = sample?["props"] ?? [String: Any]()
        return (try? JSONSerialization.data(withJSONObject: props, options: [.prettyPrinted, .sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// A module's name for people: its manifest title, the answering title in the respond slot.
    private func title(of m: [String: Any], respond: Bool) -> String {
        ModuleNames.title(m, respond: respond)
    }

    private func parse(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    private func source(for use: String) -> String? {
        ModuleNames.source(for: use, userBase: userModuleBase)
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
                let url = stored
                try await PluckkAPI.shared.setCardImage(token: token, cardId: cardId, url: url)
                imageURL = url
                PracticeSession.shared.applyExternalImage(cardId: cardId, url: url)
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

    // MARK: Split

    @ViewBuilder private var splitSection: some View {
        if !splits.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                label("New cards from this one")
                ForEach($splits) { $s in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Spacer()
                            Button(action: { splits.removeAll { $0.id == s.id } }) { Image(systemName: "xmark").font(.system(size: 10)) }
                                .buttonStyle(.plain).foregroundColor(.secondary).help("Drop this new card")
                        }
                        CardTextField(label: "Question", text: $s.question, prominent: true, minLines: 2, autofocus: true)
                        CardTextField(label: "Answer", text: $s.answer, minLines: 2)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.03)))
                }
                caption("Saved into the same deck, with this card's source.")
            }
        }
    }

    // MARK: Assistant

    private var assistantLine: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundColor(PluckkTheme.accent).font(.system(size: 12))
            TextField("Ask the assistant to change this card: “make it a map click on Sichuan”, “add audio”, “write a better context”", text: $ask)
                .textFieldStyle(.plain).font(.system(size: 12))
                .onSubmit(sendToAssistant)
            Button("Ask", action: sendToAssistant).buttonStyle(PillButtonStyle(prominent: false))
                .disabled(ask.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }

    private func sendToAssistant() {
        let text = ask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if PluckkPanel.shared?.isAssistantOpen == false { PluckkPanel.shared?.toggleAssistant() }
        AssistantSession.shared.send(text)
        ask = ""
    }

    // MARK: Loading and saving

    private var snapshot: String {
        "\(top)|\(wordsMode)|\(question)|\(fact)|\(context)|\(blankWords.sorted())|\(numberText)|\(unit)|\(tags)|\(respond.map { $0.use + $0.propsText } ?? "")|\(extras.map { "\($0.slot)\($0.use)\($0.propsText)" })|\(splits.map { $0.question + $0.answer })"
    }

    private var storedAnswer: String {
        let first = isBlanks ? typedAnswers.joined(separator: ", ") : fact.trimmingCharacters(in: .whitespacesAndNewlines)
        let more = context.trimmingCharacters(in: .whitespacesAndNewlines)
        return more.isEmpty ? first : "\(first)\n\n\(more)"
    }

    private func load() async {
        guard let token = AuthManager.shared.accessToken else { return }
        notice = nil
        changedElsewhere = false
        confirmingDelete = false
        do {
            let data = try await PluckkAPI.shared.raw(token: token, method: "GET", path: "/api/v1/cards/\(cardId)", json: nil)
            guard let card = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let spec = card["spec"] as? [String: Any]
            question = card["question"] as? String ?? ""
            let answer = card["answer"] as? String ?? ""
            let parts = answer.components(separatedBy: "\n\n")
            fact = parts.first ?? ""
            context = parts.dropFirst().joined(separator: "\n\n")
            tags = card["tags"] as? [String] ?? []
            folderId = card["folder_id"] as? String
            provenance = card["provenance"] as? [String: Any]
            imageURL = card["image_url"] as? String
            numberText = (card["numeric_answer"] as? Double).map { NumberText.format($0) } ?? ""
            unit = card["numeric_unit"] as? String ?? ""
            blankWords = []
            respond = nil
            extras = []
            splits = []
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
            if let m = spec?["modules"] as? [String: Any] {
                respond = rows(m["respond"], .respond).first
                extras = rows(m["prompt"], .prompt) + rows(m["reveal"], .reveal)
            }
            let mode = spec?["answer_type"] as? String
            if (card["answer_type"] as? String) == "numeric" { top = .number }
            else if respond != nil { top = .interactive }
            else if mode == "written" { top = .words; wordsMode = .written }
            else if TypedBlanks.expected(question: question, answer: answer) != nil { top = .words; wordsMode = .blanks; seedBlanksFromFact() }
            else { top = .recall }
            if catalogue.isEmpty {
                catalogue = LocalModules.catalogue()
                userModuleBase = LocalModules.userBase
            }
            if decks.isEmpty && allDecks.isEmpty { allDecks = (try? await PluckkAPI.shared.reviewDecks(token: token)) ?? [] }
            loaded = true
            original = snapshot
        } catch {
            notice = "Couldn't open the card: \(error.localizedDescription)"
            loaded = true
        }
    }

    private func save() {
        guard let token = AuthManager.shared.accessToken else { return }
        let q = isBlanks ? typedQuestion : question.trimmingCharacters(in: .whitespacesAndNewlines)
        let a = storedAnswer
        guard !q.isEmpty, !a.isEmpty else { notice = "A card needs a question and an answer."; return }
        if isBlanks && blankWords.isEmpty { notice = "Pick at least one word to hide, or choose another way to answer."; return }
        if top == .interactive && respond == nil { notice = "Pick how it's answered, or choose another way."; return }
        var body: [String: Any] = ["question": q, "answer": a, "tags": tags]
        switch top {
        case .number:
            guard let value = NumberText.parse(numberText) else { notice = "That number didn't read as a number."; return }
            body["answer_type"] = "numeric"
            body["numeric_answer"] = value
            body["numeric_unit"] = unit.isEmpty ? NSNull() : unit
        case .words where wordsMode == .written:
            body["answer_type"] = "written"
        default:
            body["answer_type"] = "text"
        }
        var slots: [String: Any] = [:]
        var broken: String?
        func use(_ m: EditableModule) -> [String: Any]? {
            guard let props = parse(m.propsText) else { broken = m.use; return nil }
            return ["use": m.use, "props": props]
        }
        if top == .interactive, let r = respond, let u = use(r) { slots["respond"] = u }
        for slot in [ModuleSlot.prompt, .reveal] {
            let list = extras.filter { $0.slot == slot }.compactMap(use)
            if !list.isEmpty { slots[slot.rawValue] = list }
        }
        if let broken { notice = "The settings of \(broken) need fixing (under Advanced)."; return }
        body["modules"] = slots.isEmpty ? NSNull() : slots
        let newCards = splits.filter { !$0.question.trimmingCharacters(in: .whitespaces).isEmpty && !$0.answer.trimmingCharacters(in: .whitespaces).isEmpty }
        let deck = folderId
        let source: [String: String] = {
            var s: [String: String] = ["identifier": "app:pluckk/manual", "title": "Split from a card", "containerTitle": "Pluckk"]
            if let p = provenance {
                for (k, v) in [("identifier", "identifier"), ("title", "title"), ("container_title", "containerTitle"), ("selection", "selection")] {
                    if let x = p[k] as? String { s[v] = x }
                }
            }
            return s
        }()
        saving = true
        notice = nil
        Task {
            defer { saving = false }
            do {
                _ = try await PluckkAPI.shared.raw(token: token, method: "PATCH", path: "/api/v1/cards/\(cardId)", json: body)
                for s in newCards {
                    _ = try await PluckkAPI.shared.createManualCard(token: token, question: s.question, answer: s.answer,
                                                                    folderId: deck, tags: [], provenance: source)
                }
                PracticeSession.shared.applyExternalEdit(cardId: cardId, question: q, answer: a)
                PracticeSession.shared.applyExternalTags(cardId: cardId, tags: tags)
                await PracticeSession.shared.reloadItem(cardId)
                onSaved(q, a, tags, imageURL)
                await load()
                if !newCards.isEmpty { notice = "Saved, with \(newCards.count) new card\(newCards.count == 1 ? "" : "s")." }
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
        if let deleteOverride { deleteOverride(); return }
        guard let token = AuthManager.shared.accessToken else { return }
        Task {
            do {
                let eventId = try await PluckkAPI.shared.deleteCard(token: token, cardId: cardId)
                PracticeSession.shared.removeCardExternally(cardId)
                if let onDeleted { onDeleted(eventId) } else { onRemoved() }
            } catch { notice = "Couldn't delete: \(error.localizedDescription)" }
        }
    }

    // MARK: Bits

    private func label(_ text: String) -> some View {
        Text(text.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundColor(.secondary)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// People's names for modules, and where their pages are served.
enum ModuleNames {
    static func title(_ m: [String: Any], respond: Bool) -> String {
        if respond, let t = m["respond_title"] as? String { return t }
        if let t = m["title"] as? String { return t }
        let use = m["use"] as? String ?? (m["slug"] as? String) ?? "Module"
        let id = use.split(separator: "@").first.map(String.init) ?? use
        return id.replacingOccurrences(of: "me/", with: "").replacingOccurrences(of: "-", with: " ").capitalized
    }

    static func source(for use: String, userBase: String?) -> String? {
        let parts = use.split(separator: "@")
        guard parts.count == 2 else { return nil }
        if parts[0].hasPrefix("me/"), let base = userBase { return "\(base)/\(parts[0].dropFirst(3))/\(parts[1])/index.html" }
        return "/modules/\(parts[0])/\(parts[1])/index.html"
    }
}

/// A module's settings as a form, from its manifest's props schema: text, numbers, switches and
/// choices; anything more complex, and the raw props, under Advanced.
struct ModuleSettingsForm: View {
    let schema: [String: Any]?
    @Binding var propsText: String
    @State private var advanced = false

    private var props: [String: Any] { ((try? JSONSerialization.jsonObject(with: Data(propsText.utf8))) as? [String: Any]) ?? [:] }
    private var fields: [(key: String, spec: [String: Any])] {
        let p = (schema?["properties"] as? [String: [String: Any]]) ?? [:]
        return p.filter { ["string", "number", "integer", "boolean"].contains($0.value["type"] as? String ?? "") || $0.value["enum"] != nil }
            .map { ($0.key, $0.value) }.sorted { $0.key < $1.key }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(fields, id: \.key) { f in field(f.key, f.spec) }
            if fields.isEmpty { Text(summary).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(4) }
            DisclosureGroup("Advanced", isExpanded: $advanced) {
                TextEditor(text: $propsText)
                    .font(.system(size: 11).monospaced())
                    .frame(minHeight: 90, maxHeight: 200)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            }
            .font(.system(size: 11))
            .foregroundColor(.secondary)
        }
    }

    /// The props in a line, for modules with no simple fields.
    private var summary: String {
        props.sorted { $0.key < $1.key }.prefix(4).map { k, v in "\(k): \(v is [String: Any] || v is [Any] ? "…" : "\(v)")" }.joined(separator: " · ")
    }

    @ViewBuilder private func field(_ key: String, _ spec: [String: Any]) -> some View {
        let type = spec["type"] as? String ?? ""
        HStack(spacing: 8) {
            Text(key.replacingOccurrences(of: "_", with: " ").capitalized)
                .font(.system(size: 11)).foregroundColor(.secondary).frame(width: 90, alignment: .leading)
                .help(spec["description"] as? String ?? "")
            if let options = spec["enum"] as? [String] {
                Picker("", selection: text(key, default: options.first ?? "")) { ForEach(options, id: \.self) { Text($0).tag($0) } }
                    .labelsHidden().frame(maxWidth: 160)
            } else if type == "boolean" {
                Toggle("", isOn: Binding(get: { props[key] as? Bool ?? (spec["default"] as? Bool ?? false) },
                                         set: { set(key, $0) })).labelsHidden()
            } else if type == "number" || type == "integer" {
                TextField("", text: Binding(get: { (props[key] as? NSNumber).map { "\($0)" } ?? "" },
                                            set: { set(key, type == "integer" ? (Int($0) as Any?) : (Double($0) as Any?)) }))
                    .textFieldStyle(.roundedBorder).frame(width: 90)
            } else {
                TextField("", text: text(key, default: "")).textFieldStyle(.roundedBorder)
            }
        }
    }

    private func text(_ key: String, default value: String) -> Binding<String> {
        Binding(get: { props[key] as? String ?? value }, set: { set(key, $0.isEmpty ? nil : $0) })
    }

    private func set(_ key: String, _ value: Any?) {
        var p = props
        p[key] = value
        if let data = try? JSONSerialization.data(withJSONObject: p, options: [.prettyPrinted, .sortedKeys]) {
            propsText = String(decoding: data, as: UTF8.self)
        }
    }
}

/// A module's live preview that redraws a moment after its props stop changing, and only when
/// they're valid JSON.
struct ModulePreviewDebounced: View {
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
                Text("Preview appears when the settings are complete.").font(.system(size: 11)).foregroundColor(.secondary)
            }
        }
        .task(id: propsText) {
            try? await Task.sleep(nanoseconds: 600_000_000)
            if (try? JSONSerialization.jsonObject(with: Data(propsText.utf8))) != nil { shown = propsText }
        }
    }
}
