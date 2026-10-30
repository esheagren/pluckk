import SwiftUI

/// How new cards reach you: one daily total, shared out between decks. The ring shows each
/// deck's share, and each row shows how long the deck will last at its limit. Limits save as
/// they change. More statistics over time can sit alongside this.
struct StatisticsView: View {
    @State private var decks: [DeckSummary] = []
    @State private var limits: [String: Int] = [:]      // by deck id
    @State private var dirty: Set<String> = []
    @State private var saveTask: Task<Void, Never>?
    @State private var notice: String?
    @Environment(\.colorScheme) private var colorScheme

    private static let palette = ["c8a96e", "5b9bd5", "3fb950", "a371f7", "e5534b", "39c5cf", "e5a14b", "db61a2"]

    /// Decks with new cards to give. Paused decks are left out of the mix, so out of the share too.
    private var active: [DeckSummary] { decks.filter { !$0.is_paused && $0.new > 0 } }
    private var total: Int { active.reduce(0) { $0 + limit($1) } }

    private func limit(_ deck: DeckSummary) -> Int { limits[deck.id] ?? 0 }
    private func color(_ deck: DeckSummary) -> Color {
        let index = active.firstIndex(of: deck) ?? 0
        return Color(hex: Self.palette[index % Self.palette.count])
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("New cards").font(.headline)
                HStack(spacing: 8) {
                    Text("I'll take on")
                    numberField(Binding(get: { total }, set: setTotal))
                    Text("new cards a day")
                }
                .font(.system(size: 13))

                ring.frame(maxWidth: .infinity)

                VStack(spacing: 6) {
                    ForEach(active) { row($0) }
                }

                if let notice {
                    Text(notice).font(.system(size: 12)).foregroundColor(PluckkTheme.Dark.error)
                }
                if decks.contains(where: \.is_paused) {
                    Text("Paused decks aren't shown.").font(.caption).foregroundColor(.secondary)
                }
            }
            .padding(20)
        }
        .scrollIndicators(.hidden)
        .task { await load() }
    }

    private var ring: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.06), lineWidth: 26)
            ForEach(slices, id: \.deck.id) { slice in
                Circle()
                    .trim(from: slice.start, to: slice.end)
                    .stroke(color(slice.deck), style: StrokeStyle(lineWidth: 26))
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: 0) {
                Text("\(total)").font(.system(size: 28, weight: .semibold).monospacedDigit())
                Text("a day").font(.system(size: 11)).foregroundColor(.secondary)
            }
        }
        .frame(width: 170, height: 170)
        .padding(13)
        .animation(.easeOut(duration: 0.2), value: limits)
    }

    private var slices: [(deck: DeckSummary, start: Double, end: Double)] {
        guard total > 0 else { return [] }
        var position = 0.0
        return active.map { deck in
            let start = position
            position += Double(limit(deck)) / Double(total)
            return (deck, start, position)
        }
    }

    private func row(_ deck: DeckSummary) -> some View {
        HStack(spacing: 10) {
            Circle().fill(color(deck)).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(deck.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text("\(deck.new) left · \(finishEstimate(deck))")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 8)
            if total > 0 {
                Text("\(Int((Double(limit(deck)) / Double(total) * 100).rounded()))%")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundColor(.secondary)
            }
            numberField(Binding(get: { limit(deck) }, set: { setLimit(deck, $0) }))
            Stepper("", value: Binding(get: { limit(deck) }, set: { setLimit(deck, $0) }), in: 0...500, step: 5)
                .labelsHidden()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    private func numberField(_ value: Binding<Int>) -> some View {
        TextField("", value: value, format: .number)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.center)
            .frame(width: 50)
    }

    /// At this deck's limit, how long until its new cards run out.
    private func finishEstimate(_ deck: DeckSummary) -> String {
        guard limit(deck) > 0 else { return "not coming in" }
        let days = Int((Double(deck.new) / Double(limit(deck))).rounded(.up))
        if days == 1 { return "done in a day" }
        if days < 14 { return "\(days) days" }
        if days < 60 { return "\(Int((Double(days) / 7).rounded())) weeks" }
        if days < 730 { return "\(Int((Double(days) / 30).rounded())) months" }
        return String(format: "%.1f years", Double(days) / 365)
    }

    // MARK: Changing limits

    private func setLimit(_ deck: DeckSummary, _ value: Int) {
        limits[deck.id] = min(max(value, 0), 500)
        dirty.insert(deck.id)
        scheduleSave()
    }

    /// A new total keeps the decks' proportions; rounding is settled on the largest deck.
    private func setTotal(_ value: Int) {
        let target = min(max(value, 0), 2000)
        guard !active.isEmpty, target != total else { return }
        let current = total
        var scaled: [String: Int] = [:]
        for deck in active {
            let share = current > 0 ? Double(limit(deck)) / Double(current) : 1 / Double(active.count)
            scaled[deck.id] = Int((share * Double(target)).rounded())
        }
        if let largest = active.max(by: { (scaled[$0.id] ?? 0) < (scaled[$1.id] ?? 0) }) {
            scaled[largest.id] = max(0, (scaled[largest.id] ?? 0) + target - scaled.values.reduce(0, +))
        }
        for deck in active { setLimit(deck, scaled[deck.id] ?? 0) }
    }

    /// After a short pause, so clicking through the arrows saves once.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let token = AuthManager.shared.accessToken else { return }
            let changed = decks.filter { dirty.contains($0.id) }
            dirty = []
            do {
                try await save(changed, token: token)
                notice = nil
                PracticeSession.shared.refreshTodayCounts()
            } catch {
                notice = "Couldn't save that: \(error.localizedDescription)"
            }
        }
    }

    private func save(_ changed: [DeckSummary], token: String) async throws {
        // Unfiled cards use the account default, which decks without their own limit share, so
        // those decks keep their limit first.
        if changed.contains(where: { $0.folder_id == nil }) {
            for deck in decks where deck.folder_id != nil && deck.new_per_day == nil && !changed.contains(deck) {
                try await PluckkAPI.shared.setDeckNewPerDay(token: token, folderId: deck.folder_id!, value: limit(deck))
            }
        }
        for deck in changed {
            if let folder = deck.folder_id {
                try await PluckkAPI.shared.setDeckNewPerDay(token: token, folderId: folder, value: limit(deck))
            } else {
                try await PluckkAPI.shared.setDefaultNewPerDay(token: token, value: limit(deck))
            }
        }
    }

    private func load() async {
        guard let token = AuthManager.shared.accessToken else { return }
        do {
            async let summaries = PluckkAPI.shared.reviewDecks(token: token)
            async let fallback = PluckkAPI.shared.defaultNewPerDay(token: token)
            let (loaded, standard) = try await (summaries, fallback)
            decks = loaded
            limits = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0.new_per_day ?? standard) })
        } catch {
            notice = "Couldn't load your decks: \(error.localizedDescription)"
        }
    }
}
