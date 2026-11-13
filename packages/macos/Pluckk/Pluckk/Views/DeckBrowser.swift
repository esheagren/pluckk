import SwiftUI

/// One deck's cards: a single toolbar line (deck, filter, search, practice), the cards in a grid,
/// and the card that's clicked open underneath in a full editor (see CardEditorPane).
struct DeckBrowserPanel: View {
    let deck: DeckSummary
    let allDecks: [DeckSummary]
    /// Every card in a collection (flagged, leeches), whatever its deck, rather than one deck's
    /// cards (`deck` then only carries the name and count).
    var collection: CardCollection? = nil
    private var flagged: Bool { collection != nil }

    /// What to say when nothing's here.
    private var emptyText: String {
        if let collection { return collection.empty }
        switch filter {
        case .rework: return CardCollection.flagged.empty
        case .leech: return CardCollection.leeches.empty
        case .all: return "No cards here."
        default: return "No cards match."
        }
    }
    let onSelect: (DeckSummary) -> Void
    /// A card moved or deleted, so the decks' counts are stale.
    let onChanged: () -> Void

    enum Filter: String, CaseIterable, Identifiable {
        case all, new, due, seen, rework, leech
        var id: String { rawValue }
        var state: String? { [.new, .due, .seen].contains(self) ? rawValue : nil }
        var tag: String? { self == .rework ? Rework.tag : self == .leech ? "leech" : nil }
    }

    @State private var filter = Filter.all
    @State private var cards: [LibraryCard] = []
    @State private var loading = false
    @State private var reachedEnd = false
    @State private var search = ""
    @State private var notice: String?
    /// Cards picked with ⌘- or ⇧-click, to practise together.
    @State private var selected: [String] = []
    /// The card open in the editor below the grid.
    @State private var openCard: String?
    /// The last card deleted here, for Undo.
    @State private var lastDeleted: (eventId: String, question: String)?
    @Environment(\.colorScheme) private var colorScheme

    private static let pageSize = 200
    private var isDark: Bool { colorScheme == .dark }

    private func count(_ f: Filter) -> Int? {
        switch f {
        case .all: return deck.total
        case .new: return deck.new
        case .due: return deck.due
        case .seen: return max(0, deck.total - deck.new)
        case .rework, .leech: return nil
        }
    }

    private func label(_ f: Filter) -> String {
        let name: String
        switch f {
        case .all: name = "All"
        case .new: name = "New"
        case .due: name = "Due"
        case .seen: name = "Learned"
        case .rework: name = "Flagged"
        case .leech: name = "Leeches"
        }
        return count(f).map { "\(name) \($0)" } ?? name
    }

    private var shown: [LibraryCard] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return cards }
        return cards.filter { $0.question.lowercased().contains(q) || $0.answer.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal, 16).padding(.vertical, 10)
            if let notice {
                Text(notice).font(.system(size: 12)).foregroundColor(PluckkTheme.Dark.error).padding(.horizontal, 16).padding(.bottom, 6)
            }
            if let last = lastDeleted {
                HStack(spacing: 10) {
                    Text("Deleted “\(Self.short(last.question))”").font(.system(size: 12)).foregroundColor(.secondary).lineLimit(1)
                    Button("Undo", action: undoDelete).buttonStyle(PillButtonStyle(prominent: false))
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.bottom, 6)
            }
            GeometryReader { geo in
                VStack(spacing: 0) {
                    grid
                        .frame(height: openCard == nil ? geo.size.height : max(160, geo.size.height * 0.38))
                    if let id = openCard {
                        Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
                        CardEditorPane(cardId: id, decks: allDecks,
                                       onSaved: { q, a, tags, image in
                                           if let i = cards.firstIndex(where: { $0.id == id }) {
                                               cards[i].question = q; cards[i].answer = a; cards[i].tags = tags
                                           }
                                           onChanged()     // a flag set or cleared in the editor changes the Flagged count
                                       },
                                       onRemoved: {
                                           cards.removeAll { $0.id == id }
                                           openCard = nil
                                           onChanged()
                                       },
                                       onDeleted: { eventId in
                                           deleted(id, question: cards.first { $0.id == id }?.question ?? "", eventId: eventId)
                                       },
                                       onClose: { openCard = nil })
                            .id(id)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: filter) { await reload() }
        .onChange(of: deck.id) { _ in selected = []; openCard = nil }
    }

    /// Deck, filter, search and practice, on one line.
    private var toolbar: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(allDecks) { other in Button("\(other.title) (\(other.total))") { onSelect(other) } }
            } label: {
                Text(deck.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            }
            .menuStyle(.borderlessButton).fixedSize().help(flagged ? "Show a deck" : "Show another deck")
            if !flagged {
                Menu {
                    ForEach(Filter.allCases) { f in
                        Button { filter = f } label: { Text(label(f) + (f == filter ? "  ✓" : "")) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 11))
                        Text(label(filter)).font(.system(size: 12))
                    }
                }
                .menuStyle(.borderlessButton).fixedSize().help("Show some of this deck's cards")
                flaggedToggle
            }
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundColor(.secondary)
                TextField("Search", text: $search).textFieldStyle(.plain).font(.system(size: 12))
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
            .frame(maxWidth: 240)
            if !selected.isEmpty {
                Button(action: practiseSelected) {
                    HStack(spacing: 4) { Image(systemName: "play.fill").font(.system(size: 8)); Text("Practise \(selected.count)") }
                }
                .buttonStyle(PillButtonStyle(prominent: false))
                Button(action: { selected = [] }) { Image(systemName: "xmark.circle.fill").font(.system(size: 12)) }
                    .buttonStyle(.plain).foregroundColor(.secondary).help("Clear the picked cards")
            }
            Spacer(minLength: 6)
            if flagged {
                Button(action: { practiseRun(.init(title: collection?.title ?? "Cards", cardIds: shown.map(\.id))) }) {
                    HStack(spacing: 5) { Image(systemName: "play.fill").font(.system(size: 9)); Text("Practice") }
                }
                .buttonStyle(PillButtonStyle(prominent: true))
                .disabled(shown.isEmpty)
                .help("Practise these cards now (schedule unchanged)")
            } else {
                practiceButtons
            }
        }
    }

    /// One click to this deck's flagged cards and back, rather than a line in the filter menu.
    private var flaggedToggle: some View {
        let on = filter == .rework
        return Button(action: { filter = on ? .all : .rework }) {
            HStack(spacing: 4) {
                Image(systemName: on ? "flag.fill" : "flag").font(.system(size: 10, weight: .medium))
                Text("Flagged").font(.system(size: 12))
            }
            .foregroundColor(on ? PluckkTheme.Dark.warning : .secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(on ? PluckkTheme.Dark.warning.opacity(0.14) : Color.primary.opacity(0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(on ? "Show all of this deck's cards" : "Show only this deck's flagged cards")
    }

    @ViewBuilder private var practiceButtons: some View {
        Group {
            Button(action: { practise(deck) }) {
                HStack(spacing: 5) { Image(systemName: "play.fill").font(.system(size: 9)); Text("Practice") }
            }
            .buttonStyle(PillButtonStyle(prominent: true))
            .help("Practise this deck's due and new cards")
            Menu {
                Button("All \(deck.total) cards") { practiseRun(.init(title: deck.title, folderId: .some(deck.folder_id))) }
                Button("Learned cards only (\(count(.seen) ?? 0))") {
                    practiseRun(.init(title: "\(deck.title) · learned", folderId: .some(deck.folder_id), filter: .learned))
                }
                .disabled((count(.seen) ?? 0) == 0)
                Button("Cards I missed in the last 30 days") {
                    practiseRun(.init(title: "\(deck.title) · missed", folderId: .some(deck.folder_id), filter: .missed))
                }
                Divider()
                Text("Practice ignores due dates and leaves them as they are. Again brings a card back tomorrow.")
            } label: { Image(systemName: "ellipsis.circle").font(.system(size: 13)) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Practise cards now, whatever their schedule")
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 10, alignment: .top)], spacing: 10) {
                ForEach(shown) { card in
                    CardTile(card: card, moveTargets: flagged ? allDecks.filter { $0.folder_id != card.folder_id } : allDecks.filter { $0.id != deck.id },
                             isSelected: selected.contains(card.id), isOpen: openCard == card.id,
                             onOpen: { openCard = card.id },
                             onPick: { pick(card, extend: $0) },
                             onPractise: { practiseRun(.init(title: Self.short(card.question), cardIds: [card.id])) },
                             onSave: { q, a in save(card, q, a) },
                             onToggleRework: { toggleRework(card) },
                             onMove: { move(card, to: $0) },
                             onDelete: { delete(card) })
                        .onAppear { if card.id == cards.last?.id { loadMore() } }
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
            if loading { ProgressView().controlSize(.small).padding() }
            if reachedEnd && cards.isEmpty {
                Text(emptyText)
                    .font(.system(size: 13)).foregroundColor(.secondary).padding(.top, 30)
            }
        }
        .scrollIndicators(.hidden)
    }

    // MARK: Practising picked cards

    /// ⌘-click toggles a card; ⇧-click takes in everything from the last pick to this one.
    private func pick(_ card: LibraryCard, extend: Bool) {
        if extend, let anchor = selected.last, let a = shown.firstIndex(where: { $0.id == anchor }),
           let b = shown.firstIndex(where: { $0.id == card.id }) {
            for c in shown[min(a, b)...max(a, b)] where !selected.contains(c.id) { selected.append(c.id) }
        } else if let i = selected.firstIndex(of: card.id) {
            selected.remove(at: i)
        } else {
            selected.append(card.id)
        }
    }

    private func practiseSelected() {
        let order = shown.map(\.id).filter(selected.contains)
        practiseRun(.init(title: "\(order.count) card\(order.count == 1 ? "" : "s") from \(deck.title)", cardIds: order))
        selected = []
    }

    static func short(_ text: String) -> String {
        let line = text.components(separatedBy: .newlines).first ?? text
        return line.count > 40 ? String(line.prefix(38)) + "…" : line
    }

    // MARK: Changing cards

    private func run(_ failure: String, _ body: @escaping (String) async throws -> Void) {
        guard let token = AuthManager.shared.accessToken else { return }
        notice = nil
        Task {
            do { try await body(token) } catch { notice = "\(failure): \(error.localizedDescription)" }
        }
    }

    private func save(_ card: LibraryCard, _ q: String, _ a: String) {
        run("Couldn't save") { token in
            try await PluckkAPI.shared.updateCard(token: token, cardId: card.id, question: q, answer: a)
            if let i = cards.firstIndex(where: { $0.id == card.id }) { cards[i].question = q; cards[i].answer = a }
        }
    }

    private func toggleRework(_ card: LibraryCard) {
        let tags = Rework.toggled(card.tags)
        run("Couldn't update the flag") { token in
            try await PluckkAPI.shared.setTags(token: token, cardId: card.id, tags: tags)
            if (collection == .flagged || (collection == nil && filter == .rework)) && !tags.contains(Rework.tag) {
                // Unflagged while looking at flagged cards: it leaves the list.
                cards.removeAll { $0.id == card.id }
                if openCard == card.id { openCard = nil }
            } else if let i = cards.firstIndex(where: { $0.id == card.id }) {
                cards[i].tags = tags
            }
            PracticeSession.shared.applyExternalTags(cardId: card.id, tags: tags)
            onChanged()     // the Flagged count beside the decks
        }
    }

    private func move(_ card: LibraryCard, to folderId: String?) {
        run("Couldn't move") { token in
            try await PluckkAPI.shared.moveCard(token: token, cardId: card.id, folderId: folderId)
            cards.removeAll { $0.id == card.id }
            onChanged()
        }
    }

    private func delete(_ card: LibraryCard) {
        run("Couldn't delete") { token in
            let eventId = try await PluckkAPI.shared.deleteCard(token: token, cardId: card.id)
            deleted(card.id, question: card.question, eventId: eventId)
        }
    }

    /// A card gone from the deck (from a tile or the editor): out of the grid, with Undo for a while.
    private func deleted(_ id: String, question: String, eventId: String?) {
        cards.removeAll { $0.id == id }
        if openCard == id { openCard = nil }
        PracticeSession.shared.removeCardExternally(id)
        onChanged()
        guard let eventId else { return }
        let undo = (eventId: eventId, question: question)
        lastDeleted = undo
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { if lastDeleted?.eventId == undo.eventId { lastDeleted = nil } }
    }

    private func undoDelete() {
        guard let last = lastDeleted else { return }
        lastDeleted = nil
        run("Couldn't undo") { token in
            _ = try await PluckkAPI.shared.undoReview(token: token, eventId: last.eventId)
            await reload()
            onChanged()
        }
    }

    private func reload() async {
        cards = []
        reachedEnd = false
        loading = false
        loadMore()
    }

    private func loadMore() {
        guard !loading, !reachedEnd, let token = AuthManager.shared.accessToken else { return }
        loading = true
        let wanted = filter
        Task {
            defer { loading = false }
            let fetched = collection != nil
                ? try? await PluckkAPI.shared.cards(token: token, tag: collection!.tag, limit: Self.pageSize, offset: cards.count)
                : try? await PluckkAPI.shared.cards(token: token, folderId: deck.folder_id, limit: Self.pageSize,
                                                    offset: cards.count, state: wanted.state, tag: wanted.tag)
            guard let page = fetched, wanted == filter else { return }
            cards += page
            reachedEnd = page.count < Self.pageSize
        }
    }
}

/// One card in the grid. Its flag is always in the corner; on hover come practise, edit, move
/// and delete.
private struct CardTile: View {
    let card: LibraryCard
    let moveTargets: [DeckSummary]
    var isSelected = false
    /// Open in the editor below the grid.
    var isOpen = false
    var onOpen: () -> Void = {}
    /// A ⌘- or ⇧-click: pick the card (true when ⇧ extends the pick).
    var onPick: (Bool) -> Void = { _ in }
    var onPractise: () -> Void = {}
    let onSave: (String, String) -> Void
    let onToggleRework: () -> Void
    let onMove: (String?) -> Void
    let onDelete: () -> Void

    @State private var hovering = false
    @State private var editing = false
    @State private var confirmingDelete = false
    /// The pointer is on the hover buttons: a click there is theirs, not "open the card".
    @State private var overActions = false
    @State private var q = ""
    @State private var a = ""
    @Environment(\.colorScheme) private var colorScheme
    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        Group {
            if editing { editor } else { face }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isDark ? PluckkTheme.Dark.card : PluckkTheme.Light.card))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(isSelected || isOpen ? PluckkTheme.accent : (isDark ? PluckkTheme.Dark.cardBorder : PluckkTheme.Light.cardBorder).opacity(hovering ? 1 : 0.6),
                    lineWidth: isSelected ? 2 : isOpen ? 1.5 : 1))
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isOpen ? PluckkTheme.accent.opacity(0.06) : .clear))
        .overlay(alignment: .topTrailing) {
            // Always there, not only on hover: flagging is one click from the grid.
            if !editing {
                CardIconButton(systemName: card.isMarkedForRework ? "flag.fill" : "flag",
                               help: card.isMarkedForRework ? "Flagged for rework (click to clear)" : "Flag for rework",
                               hoverTint: PluckkTheme.Dark.warning,
                               tint: card.isMarkedForRework ? PluckkTheme.Dark.warning : Color.primary.opacity(0.22),
                               action: onToggleRework)
                    .onHover { overActions = $0 }
                    .padding(3)
            }
        }
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            guard !editing else { return }
            let mods = NSEvent.modifierFlags
            if mods.contains(.command) || mods.contains(.shift) { onPick(mods.contains(.shift)) } else if !overActions { onOpen() }
        })
    }

    private var face: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(cardMarkdown(card.question))
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.trailing, 20)     // clear of the flag in the corner
            Text(cardMarkdown(card.answer.components(separatedBy: "\n\n").first ?? card.answer))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                status
                if card.answer_type == "numeric" { icon("number", "Answered with a 95% range") }
                if card.image_url != nil { icon("photo", "Has an image") }
                if let book = card.bookSource {
                    HStack(spacing: 3) {
                        Image(systemName: "book").font(.system(size: 10))
                        Text(book.shortTitle).font(.system(size: 10)).lineLimit(1)
                    }
                    .foregroundColor(.secondary)
                    .help(book.book)
                }
                if card.tags?.contains("leech") == true { icon("ladybug", "Leech: you keep forgetting it; rework it") }
                Spacer()
                if hovering {
                    actions.onHover { overActions = $0 }
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 0) {
            CardIconButton(systemName: "play.fill", help: "Practise this card now (schedule unchanged)", action: onPractise)
            CardIconButton(systemName: "pencil",
                           help: card.isSimple ? "Edit" : "Two-way and list cards are edited in the web app") {
                onOpen()
            }
            .disabled(!card.isSimple)
            Menu {
                ForEach(moveTargets) { deck in
                    Button(deck.title) { onMove(deck.folder_id) }
                }
            } label: {
                Image(systemName: "folder").font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Move to another deck")
            CardIconButton(systemName: "trash", help: "Delete card (Undo appears above)", hoverTint: Color(hex: "e5534b")) {
                onDelete()
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardTextField(label: "Question", text: $q, prominent: true, minLines: 2, autofocus: true)
            CardTextField(label: "Answer", text: $a, minLines: 2)
            HStack {
                Spacer()
                Button("Cancel") { editing = false }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundColor(.secondary)
                Button("Save") {
                    let qq = q.trimmingCharacters(in: .whitespacesAndNewlines)
                    let aa = a.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !qq.isEmpty && !aa.isEmpty { onSave(qq, aa) }
                    editing = false
                }
                .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundColor(PluckkTheme.accent)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }

    private func icon(_ name: String, _ help: String) -> some View {
        Image(systemName: name).font(.system(size: 10)).foregroundColor(.secondary).help(help)
    }

    /// New, due now, or when it next comes up.
    private var status: some View {
        let (text, tint): (String, Color) = {
            guard card.seen == true else { return ("New", Color(hex: "a371f7")) }
            guard let due = card.due_at.flatMap(Self.date) else { return ("Learned", .secondary) }
            if due <= Date() { return ("Due", PluckkTheme.accent) }
            let days = due.timeIntervalSinceNow / 86400
            let when = days < 1 ? "today" : days < 14 ? "in \(Int(days.rounded(.up))) d"
                : days < 60 ? "in \(Int((days / 7).rounded())) wk" : "in \(Int((days / 30).rounded())) mo"
            return (when, .secondary)
        }()
        return Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(tint)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.14)))
    }

    private static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}


/// Cards gathered from every deck by a tag: the ones flagged for rework, and the leeches (cards
/// forgotten again and again). Each sits above the decks on the Decks page.
enum CardCollection: String, CaseIterable, Identifiable {
    case flagged, leeches

    /// `AppState.openDeckId` when this collection is showing rather than a deck.
    var id: String { "·" + rawValue }
    var tag: String { self == .flagged ? Rework.tag : "leech" }
    var title: String { self == .flagged ? "Flagged" : "Leeches" }
    var icon: String { self == .flagged ? "flag" : "ladybug" }
    var tint: Color { self == .flagged ? PluckkTheme.Dark.warning : Color(hex: "e5534b") }
    var help: String {
        self == .flagged ? "Every card you've flagged for rework, whatever its deck"
            : "Cards you keep forgetting, whatever their deck: rework them rather than drill them"
    }
    var empty: String {
        self == .flagged ? "Nothing flagged. Flag a card on its tile, in Practice or in the editor, and it collects here."
            : "No leeches. A card becomes one after you've forgotten it several times."
    }
}

/// The Decks page: flagged cards, leeches and every deck down the side, and the chosen one's
/// cards and editor beside it. Statistics opens a deck here.
struct DeckWorkspaceView: View {
    @ObservedObject private var appState = AppState.shared
    @State private var decks: [DeckSummary] = []
    @State private var counts: [CardCollection: Int] = [:]
    @State private var problem: String?

    private var showing: CardCollection? { CardCollection.allCases.first { $0.id == appState.openDeckId } }

    private var current: DeckSummary? {
        appState.openDeckId.flatMap { id in decks.first { $0.id == id } } ?? decks.first
    }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(CardCollection.allCases) { collection in collectionRow(collection) }
                    Text("DECKS").font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundColor(.secondary)
                        .padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 6)
                    ForEach(decks) { d in
                        Button(action: { appState.openDeckId = d.id }) {
                            HStack {
                                Text(d.title).font(.system(size: 13, weight: showing == nil && current?.id == d.id ? .semibold : .regular)).lineLimit(1)
                                Spacer(minLength: 4)
                                Text("\(d.total)").font(.system(size: 11).monospacedDigit()).foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 6).fill(showing == nil && current?.id == d.id ? Color.primary.opacity(0.08) : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if let problem { Text(problem).font(.system(size: 11)).foregroundColor(.secondary).padding(10) }
                }
                .padding(.vertical, 14).padding(.horizontal, 8)
            }
            .scrollIndicators(.hidden)
            .frame(width: 210)
            Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1)
            if let collection = showing {
                DeckBrowserPanel(deck: DeckSummary(folder_id: nil, name: collection.title, is_paused: false, new_per_day: nil,
                                                   total: counts[collection] ?? 0, new: 0, due: 0),
                                 allDecks: decks, collection: collection, onSelect: { appState.openDeckId = $0.id },
                                 onChanged: { Task { await load() } })
                    .id(collection.id)
            } else if let deck = current {
                DeckBrowserPanel(deck: deck, allDecks: decks, onSelect: { appState.openDeckId = $0.id },
                                 onChanged: { Task { await load() } })
                    .id(deck.id)
            } else {
                Spacer()
            }
        }
        .task { await load() }
    }

    private func collectionRow(_ collection: CardCollection) -> some View {
        let n = counts[collection] ?? 0
        let on = showing == collection
        return Button(action: { appState.openDeckId = collection.id }) {
            HStack(spacing: 7) {
                Image(systemName: n > 0 && collection == .flagged ? "flag.fill" : collection.icon).font(.system(size: 11))
                    .foregroundColor(n > 0 ? collection.tint : .secondary)
                    .frame(width: 14)
                Text(collection.title).font(.system(size: 13, weight: on ? .semibold : .regular))
                Spacer(minLength: 4)
                if counts[collection] != nil { Text("\(n)").font(.system(size: 11).monospacedDigit()).foregroundColor(.secondary) }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.primary.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(collection.help)
    }

    private func load() async {
        guard let token = AuthManager.shared.accessToken else { return }
        do { decks = try await PluckkAPI.shared.reviewDecks(token: token) } catch { problem = "Couldn't load your decks." }
        for collection in CardCollection.allCases {
            if let cards = try? await PluckkAPI.shared.cards(token: token, tag: collection.tag, limit: 500, offset: 0) {
                counts[collection] = cards.count
            }
        }
    }
}
