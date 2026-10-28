import SwiftUI

/// What a card list shows: one deck, or every card marked for rework.
enum CardListSource: Hashable {
    case deck(DeckSummary)
    case rework
}

/// The library at a glance: cards marked for rework, then every deck with its counts; open
/// either to see and curate the cards (search, flag, edit, move, delete). Cards load a page at
/// a time.
struct DecksView: View {
    @State private var decks: [DeckSummary] = []
    @State private var reworkCount: Int?
    @State private var loading = true
    @State private var error: String?
    @State private var open: CardListSource?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let open {
                DeckCardsView(source: open, allDecks: decks) {
                    self.open = nil
                    load()
                }
            } else {
                deckList
            }
        }
        .onAppear { if decks.isEmpty { load() } }
    }

    private var deckList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Decks").font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Text("\(decks.reduce(0) { $0 + $1.total }) cards")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundColor(.secondary)
                }
                .padding(.bottom, 4)

                if loading && decks.isEmpty {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 40)
                } else if let error {
                    Text(error).font(.system(size: 13)).foregroundColor(.secondary)
                    Button("Try again") { load() }.buttonStyle(PillButtonStyle(prominent: false))
                } else {
                    ReworkRow(count: reworkCount ?? 0) { open = .rework }
                        .padding(.bottom, 6)
                    ForEach(decks) { deck in
                        DeckRow(deck: deck) { open = .deck(deck) }
                    }
                }
            }
            .padding(20)
        }
        .scrollIndicators(.hidden)
    }

    private func load() {
        guard let token = AuthManager.shared.accessToken else { return }
        loading = true
        error = nil
        Task {
            do {
                async let d = PluckkAPI.shared.reviewDecks(token: token)
                async let r = PluckkAPI.shared.cards(token: token, tag: Rework.tag, limit: 500, offset: 0)
                decks = try await d
                reworkCount = (try? await r)?.count
            } catch {
                self.error = error.localizedDescription
            }
            loading = false
        }
    }
}

/// "Marked for rework": the cards flagged from Practice (or here) for later fixing.
private struct ReworkRow: View {
    let count: Int
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "flag.fill")
                    .font(.system(size: 12))
                    .foregroundColor(PluckkTheme.Dark.warning)
                Text("Marked for rework")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("\(count)")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundColor(.secondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary.opacity(hovering ? 1 : 0.5))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(PluckkTheme.Dark.warning.opacity(hovering ? 0.14 : 0.08))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct DeckRow: View {
    let deck: DeckSummary
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let isDark = colorScheme == .dark
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(deck.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(deck.folder_id == nil ? .secondary : .primary)
                        if deck.is_paused {
                            Text("PAUSED")
                                .font(.system(size: 9, weight: .semibold)).tracking(0.5)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.primary.opacity(0.08))
                                .cornerRadius(3)
                                .foregroundColor(.secondary)
                        }
                    }
                    Text("\(deck.total) card\(deck.total == 1 ? "" : "s")")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundColor(.secondary)
                }
                Spacer()
                if deck.due > 0 { countPill("\(deck.due) due", PluckkTheme.accent) }
                if deck.new > 0 { countPill("\(deck.new) new", PluckkTheme.bidirectionalAccent) }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary.opacity(hovering ? 1 : 0.5))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isDark ? PluckkTheme.Dark.card : PluckkTheme.Light.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke((isDark ? PluckkTheme.Dark.cardBorder : PluckkTheme.Light.cardBorder).opacity(hovering ? 1 : 0.6), lineWidth: 1)
            )
            .opacity(deck.is_paused ? 0.75 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private func countPill(_ text: String, _ tint: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(tint.opacity(0.14))
            .foregroundColor(tint)
            .cornerRadius(5)
    }
}

// MARK: - One deck's cards

private struct DeckCardsView: View {
    let source: CardListSource
    let allDecks: [DeckSummary]
    let onBack: () -> Void

    private var title: String {
        switch source {
        case .deck(let d): return d.title
        case .rework: return "Marked for rework"
        }
    }
    /// Decks a card can move to (not the one it's being listed in).
    private var moveTargets: [DeckSummary] {
        switch source {
        case .deck(let d): return allDecks.filter { $0.id != d.id }
        case .rework: return allDecks
        }
    }

    private static let pageSize = 100

    @State private var cards: [LibraryCard] = []
    @State private var loading = false
    @State private var reachedEnd = false
    @State private var error: String?
    @State private var search = ""
    @State private var notice: String?

    private var shown: [LibraryCard] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return cards }
        return cards.filter { $0.question.lowercased().contains(q) || $0.answer.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        Text("Decks")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)

                Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Spacer()
                if case .deck(let d) = source {
                    Text("\(d.total)").font(.system(size: 12).monospacedDigit()).foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 10)

            TextField("Search loaded cards", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                .padding(.horizontal, 20)
                .padding(.bottom, 10)

            if let notice {
                Text(notice).font(.system(size: 12)).foregroundColor(.red).padding(.horizontal, 20).padding(.bottom, 6)
            }

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(shown) { card in
                        LibraryCardRow(card: card, moveTargets: moveTargets,
                                       onSave: { q, a in save(card, q, a) },
                                       onToggleRework: { toggleRework(card) },
                                       onMove: { move(card, to: $0) },
                                       onDelete: { delete(card) })
                    }
                    if !reachedEnd && search.isEmpty {
                        Color.clear.frame(height: 30).onAppear { loadMore() }
                        if loading { ProgressView().controlSize(.small) }
                    }
                    if let error {
                        Text(error).font(.system(size: 12)).foregroundColor(.secondary)
                    }
                    if reachedEnd && cards.isEmpty {
                        Text(source == .rework ? "Nothing marked for rework." : "No cards in this deck.").font(.system(size: 13)).foregroundColor(.secondary).padding(.top, 30)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func loadMore() {
        guard !loading, !reachedEnd, let token = AuthManager.shared.accessToken else { return }
        loading = true
        Task {
            do {
                let page: [LibraryCard]
                switch source {
                case .deck(let d):
                    page = try await PluckkAPI.shared.cards(token: token, folderId: d.folder_id,
                                                            limit: Self.pageSize, offset: cards.count)
                case .rework:
                    page = try await PluckkAPI.shared.cards(token: token, tag: Rework.tag,
                                                            limit: Self.pageSize, offset: cards.count)
                }
                cards += page
                reachedEnd = page.count < Self.pageSize
            } catch {
                self.error = error.localizedDescription
                reachedEnd = true
            }
            loading = false
        }
    }

    private func save(_ card: LibraryCard, _ q: String, _ a: String) {
        guard let token = AuthManager.shared.accessToken else { return }
        notice = nil
        Task {
            do {
                try await PluckkAPI.shared.updateCard(token: token, cardId: card.id, question: q, answer: a)
                if let i = cards.firstIndex(where: { $0.id == card.id }) {
                    cards[i].question = q
                    cards[i].answer = a
                }
            } catch {
                notice = "Couldn't save: \(error.localizedDescription)"
            }
        }
    }

    private func toggleRework(_ card: LibraryCard) {
        guard let token = AuthManager.shared.accessToken else { return }
        notice = nil
        let tags = Rework.toggled(card.tags)
        Task {
            do {
                try await PluckkAPI.shared.setTags(token: token, cardId: card.id, tags: tags)
                if source == .rework && !tags.contains(Rework.tag) {
                    cards.removeAll { $0.id == card.id }   // unflagged: it leaves this list
                } else if let i = cards.firstIndex(where: { $0.id == card.id }) {
                    cards[i].tags = tags
                }
            } catch {
                notice = "Couldn't update the flag: \(error.localizedDescription)"
            }
        }
    }

    private func move(_ card: LibraryCard, to folderId: String?) {
        guard let token = AuthManager.shared.accessToken else { return }
        notice = nil
        Task {
            do {
                try await PluckkAPI.shared.moveCard(token: token, cardId: card.id, folderId: folderId)
                if case .deck = source {
                    cards.removeAll { $0.id == card.id }
                } else if let i = cards.firstIndex(where: { $0.id == card.id }) {
                    cards[i].folder_id = folderId
                }
            } catch {
                notice = "Couldn't move: \(error.localizedDescription)"
            }
        }
    }

    private func delete(_ card: LibraryCard) {
        guard let token = AuthManager.shared.accessToken else { return }
        notice = nil
        Task {
            do {
                _ = try await PluckkAPI.shared.deleteCard(token: token, cardId: card.id)
                cards.removeAll { $0.id == card.id }
            } catch {
                notice = "Couldn't delete: \(error.localizedDescription)"
            }
        }
    }
}

/// One card in a deck: question and answer; on hover, edit / move / delete.
private struct LibraryCardRow: View {
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

    var body: some View {
        let isDark = colorScheme == .dark
        VStack(alignment: .leading, spacing: 6) {
            if editing {
                TextField("Question", text: $q, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 13, weight: .semibold)).lineLimit(1...6)
                TextField("Answer", text: $a, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 13)).lineLimit(1...6)
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
                }
            } else {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(card.question)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(3)
                        Text(card.answer)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    if card.isMarkedForRework && !(hovering || confirmingDelete) {
                        Image(systemName: "flag.fill").font(.system(size: 10)).foregroundColor(PluckkTheme.Dark.warning)
                    }
                    if card.image_url != nil {
                        Image(systemName: "photo").font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    if hovering || confirmingDelete { actions }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isDark ? PluckkTheme.Dark.card : PluckkTheme.Light.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke((isDark ? PluckkTheme.Dark.cardBorder : PluckkTheme.Light.cardBorder).opacity(0.6), lineWidth: 1)
        )
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var actions: some View {
        if confirmingDelete {
            HStack(spacing: 8) {
                Button("Cancel") { confirmingDelete = false }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundColor(.secondary)
                Button("Delete") { confirmingDelete = false; onDelete() }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundColor(Color(hex: "e5534b"))
            }
        } else {
            HStack(spacing: 0) {
                CopyCardIDButton(cardId: card.id)
                CardIconButton(systemName: card.isMarkedForRework ? "flag.fill" : "flag",
                               help: card.isMarkedForRework ? "Unmark" : "Mark for rework",
                               hoverTint: PluckkTheme.Dark.warning,
                               tint: card.isMarkedForRework ? PluckkTheme.Dark.warning : nil,
                               action: onToggleRework)
                CardIconButton(systemName: "pencil",
                               help: card.isSimple ? "Edit" : "Two-way and list cards are edited in the web app") {
                    q = card.question
                    a = card.answer
                    editing = true
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
                .frame(width: 26, height: 26)
                .help("Move to another deck")
                CardIconButton(systemName: "trash", help: "Delete", hoverTint: Color(hex: "e5534b")) {
                    confirmingDelete = true
                }
            }
        }
    }
}
