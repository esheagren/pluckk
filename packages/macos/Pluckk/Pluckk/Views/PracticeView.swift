import SwiftUI
import AppKit

// MARK: - Session

/// The practice session, kept outside the view so collapsing the panel or switching tabs
/// doesn't lose your place. The server deals the session and schedules every rating; this
/// only walks the queue (an "again" goes back to the end, as in the web app).
@MainActor
final class PracticeSession: ObservableObject {
    static let shared = PracticeSession()

    enum Phase { case idle, loading, reviewing, done, failed(String) }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var queue: [ReviewItem] = []
    @Published private(set) var index = 0
    @Published var revealed = false
    @Published private(set) var reviewedCount = 0
    @Published private(set) var busy = false
    @Published private(set) var notice: String?
    @Published private(set) var editing = false
    /// A timed sprint ran out (SessionTimer); Practice shows "Good job" and the practice grid
    /// for a few seconds, then returns to the next card on its own.
    @Published private(set) var timesUp = false

    /// The latest undoable action: a rating, or a delete (with the queue entries it removed).
    private enum LastAction {
        case rating(eventId: String, item: ReviewItem, index: Int, wasAgain: Bool)
        case deletion(eventId: String, index: Int, removed: [ReviewItem])
    }

    private var shownAt = Date()
    private var last: LastAction?

    var current: ReviewItem? { index < queue.count ? queue[index] : nil }
    var canUndo: Bool { last != nil && !busy }

    private init() {}

    func startIfNeeded() {
        if case .idle = phase { start() }
    }

    /// A timed sprint begins: make sure there are cards to work through.
    func beginSprint() {
        timesUp = false
        switch phase {
        case .idle, .done, .failed: start()
        default: break
        }
    }

    func timeUp() {
        editing = false
        revealed = false
        timesUp = true
    }

    /// The "Good job" moment is over: back to the next card, unrevealed. Nothing asks you to go
    /// on; revealing it simply starts another sprint.
    func finishCelebration() { timesUp = false }

    /// Revealing a card starts a sprint if none is running: practising *is* starting. Suppressed
    /// after a manual stop, until the panel is next closed.
    private(set) var autoStartSuppressed = false
    func suppressAutoStart() { autoStartSuppressed = true }
    func panelClosed() { autoStartSuppressed = false }

    /// Opening Practice after a finished (or failed) session deals a fresh one: more may be due.
    func refreshIfFinished() {
        switch phase {
        case .done, .failed: start()
        default: break
        }
    }

    func start() {
        guard let token = AuthManager.shared.accessToken else { return }
        phase = .loading
        notice = nil
        Task {
            do {
                let items = try await PluckkAPI.shared.reviewSession(token: token)
                queue = items
                index = 0
                reviewedCount = 0
                revealed = false
                editing = false
                last = nil
                shownAt = Date()
                phase = items.isEmpty ? .done : .reviewing
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func reveal() {
        guard current != nil, !revealed else { return }
        withAnimation(.easeOut(duration: 0.15)) { revealed = true }
        if !SessionTimer.shared.isRunning && !autoStartSuppressed && !timesUp {
            SessionTimer.shared.start()
        }
    }

    func rate(_ rating: ReviewRating) {
        guard let item = current, revealed, !busy, !editing, let token = AuthManager.shared.accessToken else { return }
        busy = true
        notice = nil
        let elapsed = Int(Date().timeIntervalSince(shownAt) * 1000)
        Task {
            defer { busy = false }
            do {
                let result = try await PluckkAPI.shared.submitReview(token: token, item: item, rating: rating, responseMs: elapsed)
                last = .rating(eventId: result.event_id, item: item, index: index, wasAgain: rating == .again)
                reviewedCount += 1
                if rating == .again {
                    var requeued = item
                    requeued.previews = result.previews
                    requeued.is_new = false
                    queue.remove(at: index)
                    queue.append(requeued)
                } else {
                    index += 1
                }
                advance()
            } catch {
                notice = "Couldn't save that rating: \(error.localizedDescription)"
            }
        }
    }

    func undo() {
        guard let last, !busy, !editing, let token = AuthManager.shared.accessToken else { return }
        busy = true
        notice = nil
        Task {
            defer { busy = false }
            do {
                switch last {
                case let .rating(eventId, item, at, wasAgain):
                    let restored = try await PluckkAPI.shared.undoReview(token: token, eventId: eventId) ?? item
                    // An "again" moved the item to the end; undo is only offered for the latest
                    // action, so that copy is still the last one.
                    if wasAgain, !queue.isEmpty { queue.removeLast() }
                    let i = min(at, queue.count)
                    queue.insert(restored, at: i)
                    index = i
                    reviewedCount = max(0, reviewedCount - 1)
                case let .deletion(eventId, at, removed):
                    _ = try await PluckkAPI.shared.undoReview(token: token, eventId: eventId)
                    let i = min(at, queue.count)
                    queue.insert(contentsOf: removed, at: i)
                    index = i
                }
                self.last = nil
                phase = .reviewing
                revealed = false
                shownAt = Date()
            } catch {
                notice = "Couldn't undo: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Edit and delete

    /// Two-way and list cards have several components; the API edits those only by full spec.
    var canEditCurrent: Bool { (current?.component_count ?? 0) == 1 }

    func beginEdit() {
        guard canEditCurrent, !busy else { return }
        notice = nil
        editing = true
    }

    func cancelEdit() { editing = false }

    func saveEdit(question: String, answer: String) {
        guard let item = current, editing, !busy, let token = AuthManager.shared.accessToken else { return }
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let a = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !a.isEmpty else { notice = "Question and answer can't be empty."; return }
        if q == item.question && a == item.answer { editing = false; return }
        busy = true
        notice = nil
        Task {
            defer { busy = false }
            do {
                try await PluckkAPI.shared.updateCard(token: token, cardId: item.card_id, question: q, answer: a)
                for i in queue.indices where queue[i].card_id == item.card_id {
                    queue[i].question = q
                    queue[i].answer = a
                }
                editing = false
            } catch {
                notice = "Couldn't save the edit: \(error.localizedDescription)"
            }
        }
    }

    func deleteCurrent() {
        guard let item = current, !busy, !editing, let token = AuthManager.shared.accessToken else { return }
        busy = true
        notice = nil
        Task {
            defer { busy = false }
            do {
                let eventId = try await PluckkAPI.shared.deleteCard(token: token, cardId: item.card_id)
                // Drop every component of this card still ahead in the queue.
                let removed = queue[index...].filter { $0.card_id == item.card_id }
                queue = Array(queue[..<index]) + queue[index...].filter { $0.card_id != item.card_id }
                last = eventId.map { .deletion(eventId: $0, index: index, removed: removed) }
                advance()
            } catch {
                notice = "Couldn't delete the card: \(error.localizedDescription)"
            }
        }
    }

    private func advance() {
        editing = false
        revealed = false
        shownAt = Date()
        if index >= queue.count { phase = .done }
    }
}

// MARK: - View

struct PracticeView: View {
    @ObservedObject private var session = PracticeSession.shared
    @Environment(\.colorScheme) private var colorScheme
    /// The image shown full-panel after clicking it on the card.
    @State private var zoomed: URL?
    @State private var editQuestion = ""
    @State private var editAnswer = ""
    @State private var confirmingDelete = false

    private var isDark: Bool { colorScheme == .dark }
    private var primaryText: Color { isDark ? PluckkTheme.Dark.textPrimary : PluckkTheme.Light.textPrimary }
    private var answerText: Color { isDark ? PluckkTheme.Dark.answerText : PluckkTheme.Light.answerText }
    private var mutedText: Color { isDark ? PluckkTheme.Dark.textTertiary : PluckkTheme.Light.textTertiary }
    private var rule: Color { isDark ? PluckkTheme.Dark.cardBorder : PluckkTheme.Light.cardBorder }
    private var cardSurface: Color { isDark ? PluckkTheme.Dark.card : PluckkTheme.Light.card }

    var body: some View {
        Group {
            if session.timesUp {
                SprintCelebration { session.finishCelebration() }
                    .transition(.opacity)
            } else {
            switch session.phase {
            case .idle, .loading:
                centered { ProgressView().controlSize(.small) }
            case .failed(let message):
                centered {
                    VStack(spacing: 12) {
                        Text("Couldn't start a session").font(.system(size: 15, weight: .semibold)).foregroundColor(primaryText)
                        Text(message).font(.system(size: 13)).foregroundColor(mutedText).multilineTextAlignment(.center)
                        Button("Try again") { session.start() }.buttonStyle(PillButtonStyle(prominent: true))
                    }
                    .padding(24)
                }
            case .done:
                doneState
            case .reviewing:
                if let item = session.current { reviewing(item) }
            }
            }
        }
        .overlay(alignment: .top) { SprintBar() }
        .overlay { if let zoomed { lightbox(zoomed) } }
        .onAppear { session.startIfNeeded() }
        .onChange(of: session.current?.id) { _ in
            zoomed = nil
            confirmingDelete = false
        }
    }

    private func lightbox(_ url: URL) -> some View {
        ZStack {
            Color.black.opacity(0.92)
            AsyncImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fit)
            } placeholder: {
                ProgressView().controlSize(.small)
            }
            .padding(12)
            Button("") { zoomed = nil }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
        }
        .contentShape(Rectangle())
        .onTapGesture { zoomed = nil }
        .help("Click or press Esc to close")
        .transition(.opacity)
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack { Spacer(); content(); Spacer() }.frame(maxWidth: .infinity)
    }

    // MARK: Reviewing

    private func reviewing(_ item: ReviewItem) -> some View {
        VStack(spacing: 14) {
            header(item)

            // A card with an image fills the height so the image can use every spare point
            // (and grows with the panel); text-only cards scroll if they run long.
            if item.image_url != nil {
                card(item)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 4)
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    card(item)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 4)
                }
                .scrollIndicators(.hidden)
            }

            if let notice = session.notice {
                Text(notice).font(.system(size: 12)).foregroundColor(PluckkTheme.Dark.error)
                    .padding(.horizontal, 20)
            }

            footer(item)
                .padding(.horizontal, 20)
                .padding(.bottom, 18)
        }
        .padding(.top, 10)
    }

    private func header(_ item: ReviewItem) -> some View {
        HStack(spacing: 8) {
            if let deck = item.folder?.name {
                Text(deck.uppercased())
                    .font(.system(size: 10, weight: .semibold)).tracking(0.6)
                    .foregroundColor(PluckkTheme.accent)
            }
            if item.is_new {
                Text("NEW")
                    .font(.system(size: 10, weight: .semibold)).tracking(0.6)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(PluckkTheme.bidirectionalAccent.opacity(0.14))
                    .foregroundColor(PluckkTheme.bidirectionalAccent)
                    .cornerRadius(4)
            }
            Spacer()
            if !session.editing {
                Button(action: { session.undo() }) {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundColor(mutedText)
                .opacity(session.canUndo ? 1 : 0)
                .disabled(!session.canUndo)
                .keyboardShortcut("z", modifiers: [])
                .help("Undo (Z)")
            }
        }
        .padding(.horizontal, 22)
    }

    private func card(_ item: ReviewItem) -> some View {
        Group {
            if session.editing {
                editor
            } else {
                cardContent(item)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, minHeight: 160, maxHeight: item.image_url != nil ? .infinity : nil)
        .background(cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(rule.opacity(0.7), lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            if !session.editing { cardActions.padding(10) }
        }
        .shadow(color: Color.black.opacity(isDark ? 0.55 : 0.10), radius: 12, y: 4)
        .contentShape(Rectangle())
        .onTapGesture { if !session.editing { session.reveal() } }
        .id(item.id)
    }

    private func cardContent(_ item: ReviewItem) -> some View {
        VStack(spacing: 16) {
            Text(item.question)
                .font(.system(size: fittedSize(item.question), weight: .semibold))
                .foregroundColor(primaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            if !session.revealed, let url = item.image_url.flatMap(URL.init(string:)) {
                cardImage(url)
            }

            if session.revealed {
                Rectangle().fill(rule).frame(height: 1)
                Text(item.answer)
                    .font(.system(size: fittedSize(item.answer) - 1))
                    .foregroundColor(answerText)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
                if let url = item.image_url.flatMap(URL.init(string:)) {
                    cardImage(url)
                }
                if let source = item.source_url, let url = URL(string: source), url.scheme?.hasPrefix("http") == true {
                    Button(action: { NSWorkspace.shared.open(url) }) {
                        Text("Source · \(url.host ?? source)")
                            .font(.system(size: 11))
                            .foregroundColor(mutedText)
                            .underline()
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Edit and delete, top-right of the card. Delete asks once, inline; Z undoes it.
    @ViewBuilder
    private var cardActions: some View {
        if confirmingDelete {
            HStack(spacing: 8) {
                Text("Delete this card?").font(.system(size: 12)).foregroundColor(mutedText)
                Button("Cancel") { confirmingDelete = false }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundColor(mutedText)
                Button("Delete") {
                    confirmingDelete = false
                    session.deleteCurrent()
                }
                .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundColor(Color(hex: "e5534b"))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(cardSurface))
            .overlay(Capsule().stroke(rule, lineWidth: 1))
        } else {
            HStack(spacing: 2) {
                CardIconButton(systemName: "pencil",
                               help: session.canEditCurrent ? "Edit card" : "Two-way and list cards are edited in the web app") {
                    editQuestion = session.current?.question ?? ""
                    editAnswer = session.current?.answer ?? ""
                    session.beginEdit()
                }
                .disabled(!session.canEditCurrent || session.busy)
                CardIconButton(systemName: "trash", help: "Delete card", hoverTint: Color(hex: "e5534b")) {
                    confirmingDelete = true
                }
                .disabled(session.busy)
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 14) {
            editField("Question", text: $editQuestion, weight: .semibold)
            editField("Answer", text: $editAnswer, weight: .regular)
        }
    }

    private func editField(_ label: String, text: Binding<String>, weight: Font.Weight) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold)).tracking(0.6)
                .foregroundColor(mutedText)
            TextField(label, text: text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: weight))
                .foregroundColor(primaryText)
                .lineLimit(1...10)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isDark ? PluckkTheme.Dark.table : PluckkTheme.Light.table)
                )
        }
    }

    /// Takes whatever room the text leaves (never less than 120pt); click to see it full-panel.
    private func cardImage(_ url: URL) -> some View {
        AsyncImage(url: url) { image in
            image.resizable().aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } placeholder: {
            ProgressView().controlSize(.small)
        }
        .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { zoomed = url } }
        .onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .help("Click to enlarge")
    }

    @ViewBuilder
    private func footer(_ item: ReviewItem) -> some View {
        if session.editing {
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { session.cancelEdit() }
                    .buttonStyle(PillButtonStyle(prominent: false))
                    .keyboardShortcut(.cancelAction)
                Button(action: { session.saveEdit(question: editQuestion, answer: editAnswer) }) {
                    HStack(spacing: 6) {
                        Text("Save")
                        Text("⌘↩").font(.system(size: 11, weight: .medium)).opacity(0.6)
                    }
                }
                .buttonStyle(PillButtonStyle(prominent: true))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(session.busy)
            }
        } else if session.revealed {
            HStack(spacing: 8) {
                ForEach(ReviewRating.allCases, id: \.self) { rating in
                    RatingButton(rating: rating, interval: item.previews.label(for: rating)) { session.rate(rating) }
                        .disabled(session.busy)
                        .keyboardShortcut(KeyEquivalent(rating.key), modifiers: [])
                }
            }
        } else {
            Button(action: { session.reveal() }) {
                HStack(spacing: 8) {
                    Text("Show answer")
                    KeyCap("space")
                }
            }
            .buttonStyle(QuietButtonStyle())
            .keyboardShortcut(.space, modifiers: [])
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Done

    private var doneState: some View {
        centered {
            VStack(spacing: 14) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 30, weight: .light))
                    .foregroundColor(PluckkTheme.accent)
                Text(session.reviewedCount > 0 ? "Session done" : "Nothing due right now")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(primaryText)
                if session.reviewedCount > 0 {
                    Text("\(session.reviewedCount) review\(session.reviewedCount == 1 ? "" : "s")")
                        .font(.system(size: 13))
                        .foregroundColor(mutedText)
                }
                HStack(spacing: 10) {
                    if session.canUndo {
                        Button("Undo last") { session.undo() }.buttonStyle(PillButtonStyle(prominent: false))
                    }
                    Button("Start another") { session.start() }.buttonStyle(PillButtonStyle(prominent: true))
                }
                .padding(.top, 4)
                Button(action: {
                    if let url = URL(string: Config.webappURL) { NSWorkspace.shared.open(url) }
                }) {
                    Text("Open Pluckk in the browser ↗").font(.system(size: 12)).foregroundColor(mutedText)
                }
                .buttonStyle(.plain)
            }
            .padding(24)
        }
    }

    /// Type that fits its content: short prompts large, long ones step down (as in the web app).
    private func fittedSize(_ text: String) -> CGFloat {
        let n = text.trimmingCharacters(in: .whitespacesAndNewlines).count
        if n <= 60 { return 22 }
        if n <= 140 { return 19 }
        if n <= 320 { return 16 }
        return 14
    }
}

/// End of a sprint: "Good job", then the practice-day grid, held briefly, then it fades and the
/// next card is there again. No buttons and no count to beat; a click skips it.
struct SprintCelebration: View {
    let onDone: () -> Void
    @State private var showGrid = false
    @State private var finished = false

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Text("Good job")
                .font(.system(size: 26, weight: .semibold))
                .foregroundColor(PluckkTheme.accent)
            ActivityGrid()
                .frame(maxWidth: 320)
                .opacity(showGrid ? 1 : 0)
                .offset(y: showGrid ? 0 : 6)
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .task {
            // A moment for "Good job", then the days, held for two seconds.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            withAnimation(.easeOut(duration: 0.35)) { showGrid = true }
            try? await Task.sleep(nanoseconds: 2_350_000_000)
            finish()
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        withAnimation(.easeInOut(duration: 0.4)) { onDone() }
    }
}

/// Practice shows time, never how many cards are left: while a sprint runs, a thin bar along
/// the top fills with the minutes used. No sprint, no bar; the point is to start, not to finish.
struct SprintBar: View {
    @ObservedObject private var timer = SessionTimer.shared

    var body: some View {
        if timer.isRunning {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.primary.opacity(0.06))
                    Rectangle()
                        .fill(PluckkTheme.accent.opacity(0.85))
                        .frame(width: geo.size.width * timer.progress)
                        .animation(.linear(duration: 1), value: timer.progress)
                }
            }
            .frame(height: 3)
            .transition(.opacity)
        }
    }
}

/// A small, quiet capsule: hairline outline, muted text that brightens on hover.
struct QuietButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        QuietButton(configuration: configuration, isDark: colorScheme == .dark)
    }

    private struct QuietButton: View {
        let configuration: ButtonStyleConfiguration
        let isDark: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color.primary.opacity(hovering ? 0.9 : 0.6))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.primary.opacity(hovering ? 0.06 : 0)))
                .overlay(Capsule().stroke(isDark ? PluckkTheme.Dark.cardBorder : PluckkTheme.Light.cardBorder, lineWidth: 1))
                .contentShape(Capsule())
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

/// A key name drawn as a tiny keycap.
struct KeyCap: View {
    let key: String
    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundColor(Color.primary.opacity(0.45))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(Color.primary.opacity(0.18), lineWidth: 1))
    }
}

/// A small icon button in the card's top-right corner.
struct CardIconButton: View {
    let systemName: String
    let help: String
    var hoverTint: Color? = nil
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(hovering && isEnabled ? (hoverTint ?? Color.primary.opacity(0.8)) : Color.primary.opacity(0.35))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.primary.opacity(hovering && isEnabled ? 0.08 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// One of the four rating buttons: the rating, the interval it would set, and its key.
struct RatingButton: View {
    let rating: ReviewRating
    let interval: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    private var tint: Color {
        switch rating {
        case .again: return Color(hex: "e5534b")
        case .hard: return Color(hex: "d4a72c")
        case .good: return Color(hex: "3fb950")
        case .easy: return PluckkTheme.bidirectionalAccent
        }
    }

    var body: some View {
        let isDark = colorScheme == .dark
        Button(action: action) {
            VStack(spacing: 3) {
                Text(rating.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(isDark ? PluckkTheme.Dark.textPrimary : PluckkTheme.Light.textPrimary)
                Text("\(interval) · \(String(rating.key))")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(tint)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isDark ? PluckkTheme.Dark.card : PluckkTheme.Light.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(hovering ? tint.opacity(0.8) : (isDark ? PluckkTheme.Dark.cardBorder : PluckkTheme.Light.cardBorder),
                            lineWidth: 1)
            )
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
