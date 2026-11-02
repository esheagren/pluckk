import SwiftUI

/// One deck's cards, beside the Statistics ring: two to a row, each labelled new, due or when it's
/// next due, with filters, search, and on hover edit, flag, move and delete.
struct DeckBrowserPanel: View {
    let deck: DeckSummary
    let allDecks: [DeckSummary]
    let onSelect: (DeckSummary) -> Void
    /// A card moved or deleted, so the decks' counts are stale.
    let onChanged: () -> Void

    enum Filter: String, CaseIterable, Identifiable {
        case all, new, due, seen
        var id: String { rawValue }
        var state: String? { self == .all ? nil : rawValue }
    }

    @State private var filter = Filter.all
    @State private var cards: [LibraryCard] = []
    @State private var loading = false
    @State private var reachedEnd = false
    @State private var search = ""
    @State private var notice: String?
    @Environment(\.colorScheme) private var colorScheme

    private static let pageSize = 200
    private var isDark: Bool { colorScheme == .dark }

    private func count(_ f: Filter) -> Int {
        switch f {
        case .all: return deck.total
        case .new: return deck.new
        case .due: return deck.due
        case .seen: return max(0, deck.total - deck.new)
        }
    }

    private func label(_ f: Filter) -> String {
        switch f {
        case .all: return "All \(count(f))"
        case .new: return "New \(count(f))"
        case .due: return "Due \(count(f))"
        case .seen: return "Learned \(count(f))"
        }
    }

    private var shown: [LibraryCard] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return cards }
        return cards.filter { $0.question.lowercased().contains(q) || $0.answer.lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Menu {
                    ForEach(allDecks) { other in
                        Button("\(other.title) (\(other.total))") { onSelect(other) }
                    }
                } label: {
                    Text(deck.title).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Show another deck")
                Text("\(deck.total) cards").font(.system(size: 12)).foregroundColor(.secondary)
                Spacer()
                Button(action: { practise(deck) }) {
                    HStack(spacing: 5) {
                        Image(systemName: "play.fill").font(.system(size: 9))
                        Text("Practice")
                    }
                }
                .buttonStyle(PillButtonStyle(prominent: true))
                .help("Practise just this deck")
            }
            if let notice {
                Text(notice).font(.system(size: 12)).foregroundColor(PluckkTheme.Dark.error)
            }
            Picker("", selection: $filter) {
                ForEach(Filter.allCases) { Text(label($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            TextField("Search these cards", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))

            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10, alignment: .top), GridItem(.flexible(), alignment: .top)],
                          spacing: 10) {
                    ForEach(shown) { card in
                        CardTile(card: card, moveTargets: allDecks.filter { $0.id != deck.id },
                                 onSave: { q, a in save(card, q, a) },
                                 onToggleRework: { toggleRework(card) },
                                 onMove: { move(card, to: $0) },
                                 onDelete: { delete(card) })
                            .onAppear { if card.id == cards.last?.id { loadMore() } }
                    }
                }
                if loading { ProgressView().controlSize(.small).padding() }
                if reachedEnd && cards.isEmpty {
                    Text("No cards here.").font(.system(size: 13)).foregroundColor(.secondary).padding(.top, 30)
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: filter) { await reload() }
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
            if let i = cards.firstIndex(where: { $0.id == card.id }) { cards[i].tags = tags }
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
            _ = try await PluckkAPI.shared.deleteCard(token: token, cardId: card.id)
            cards.removeAll { $0.id == card.id }
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
            guard let page = try? await PluckkAPI.shared.cards(token: token, folderId: deck.folder_id, limit: Self.pageSize,
                                                              offset: cards.count, state: wanted.state),
                  wanted == filter else { return }
            cards += page
            reachedEnd = page.count < Self.pageSize
        }
    }
}

/// One card in the grid. On hover: edit, flag, move and delete; editing happens in place, and
/// delete asks once.
private struct CardTile: View {
    let card: LibraryCard
    let moveTargets: [DeckSummary]
    let onSave: (String, String) -> Void
    let onToggleRework: () -> Void
    let onMove: (String?) -> Void
    let onDelete: () -> Void

    @State private var hovering = false
    @State private var editing = false
    @State private var confirmingDelete = false
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
            .stroke((isDark ? PluckkTheme.Dark.cardBorder : PluckkTheme.Light.cardBorder).opacity(hovering ? 1 : 0.6), lineWidth: 1))
        .onHover { hovering = $0 }
    }

    private var face: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(cardMarkdown(card.question))
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
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
                if card.bookSource != nil { icon("book", card.bookSource?.book ?? "") }
                if card.isMarkedForRework { icon("flag.fill", "Marked for rework") }
                Spacer()
                if confirmingDelete {
                    Text("Delete?").font(.system(size: 11)).foregroundColor(.secondary)
                    Button("Cancel") { confirmingDelete = false }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundColor(.secondary)
                    Button("Delete") { confirmingDelete = false; onDelete() }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundColor(Color(hex: "e5534b"))
                } else if hovering {
                    actions
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 0) {
            CardIconButton(systemName: "pencil",
                           help: card.isSimple ? "Edit" : "Two-way and list cards are edited in the web app") {
                q = card.question
                a = card.answer
                editing = true
            }
            .disabled(!card.isSimple)
            CardIconButton(systemName: card.isMarkedForRework ? "flag.fill" : "flag",
                           help: card.isMarkedForRework ? "Unmark" : "Mark for rework",
                           hoverTint: PluckkTheme.Dark.warning,
                           tint: card.isMarkedForRework ? PluckkTheme.Dark.warning : nil,
                           action: onToggleRework)
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
            CardIconButton(systemName: "trash", help: "Delete card", hoverTint: Color(hex: "e5534b")) {
                confirmingDelete = true
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
