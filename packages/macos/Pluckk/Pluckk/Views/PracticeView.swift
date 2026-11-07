import SwiftUI
import AppKit

// MARK: - Session

/// ⌘+ and ⌘- on the card's text.
enum CardTextScale {
    static let key = "cardTextScale"

    static func step(_ delta: Double) {
        let current = UserDefaults.standard.double(forKey: key)
        let next = ((current > 0 ? current : 1) + delta) * 10
        UserDefaults.standard.set(min(max(next.rounded() / 10, 0.7), 2.5), forKey: key)
    }

    static func reset() { UserDefaults.standard.set(1.0, forKey: key) }
}

/// A new card started from the Practice editor, to split the one being edited.
struct SplitCard: Identifiable {
    let id = UUID()
    var question = ""
    var answer = ""
}

/// What saving the card editor does to the card's number.
enum CardNumberChange {
    case keep, clear
    case set(Double, String?)
}

/// What saving the card editor does to the card's image.
enum CardImageChange {
    case keep, remove
    case replace(NSImage)
}

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
    @Published var revealed = false {
        // When the answer showed: time-to-reveal is how long retrieval took (see stats/learning).
        didSet { if revealed && !oldValue { revealedAt = Date() } else if !revealed { revealedAt = nil } }
    }
    private var revealedAt: Date?
    @Published private(set) var reviewedCount = 0
    @Published private(set) var busy = false
    @Published var notice: String?
    @Published private(set) var editing = false
    /// A timed sprint ran out (SessionTimer); Practice shows "Good job" and the practice grid
    /// for a few seconds, then returns to the next card on its own.
    @Published private(set) var timesUp = false

    /// The latest undoable action: a rating, or a delete (with the queue entries it removed).
    private enum LastAction {
        case rating(eventId: String?, item: ReviewItem, index: Int, wasAgain: Bool)   // nil: a practice rating, nothing to undo on the server
        case deletion(eventId: String, index: Int, removed: [ReviewItem])
    }

    private var shownAt = Date()
    /// Undo goes back through the session's recent actions, newest first.
    private var history: [LastAction] = []
    private let historyLimit = 20

    var current: ReviewItem? { index < queue.count ? queue[index] : nil }
    var canUndo: Bool { !history.isEmpty && !busy }

    private func remember(_ action: LastAction) {
        history.append(action)
        if history.count > historyLimit { history.removeFirst() }
    }

    private init() {}

    func startIfNeeded() {
        if case .idle = phase { start() }
    }

    /// A timed sprint begins: make sure there are cards to work through.
    func beginSprint() {
        timesUp = false
        celebrateAfterThisCard = false
        switch phase {
        case .idle, .done, .failed: start()
        default: break
        }
    }

    /// Time ran out. On a question, celebrate now. With the answer showing (or mid-edit), let the
    /// card finish: "Good job" comes once it's rated (or deleted).
    func timeUp() {
        if revealed || editing {
            celebrateAfterThisCard = true
        } else {
            timesUp = true
        }
    }
    private var celebrateAfterThisCard = false

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

    /// What's left today across the mix, shown beside the timer.
    @Published private(set) var todayCounts: TodayCounts?
    private var countsRequest = 0

    /// Re-fetch the counts; a slower, older response never overwrites a newer one.
    func refreshTodayCounts() {
        guard let token = AuthManager.shared.accessToken else { return }
        countsRequest += 1
        let request = countsRequest
        Task {
            if let counts = try? await PluckkAPI.shared.reviewToday(token: token), request == countsRequest {
                todayCounts = counts
            }
        }
    }

    // MARK: Changes made elsewhere (the assistant), so the queue doesn't show stale cards

    func applyExternalEdit(cardId: String, question: String?, answer: String?, sourceURL: String? = nil) {
        for i in queue.indices where queue[i].card_id == cardId {
            if let question { queue[i].question = question }
            if let answer { queue[i].answer = answer }
            if let sourceURL { queue[i].source_url = sourceURL }
        }
    }

    func applyExternalImage(cardId: String, url: String) {
        for i in queue.indices where queue[i].card_id == cardId { queue[i].image_url = url }
    }

    func applyExternalTags(cardId: String, tags: [String]) {
        for i in queue.indices where queue[i].card_id == cardId { queue[i].tags = tags }
    }

    func removeCardExternally(_ cardId: String) {
        guard index <= queue.count else { return }
        let wasCurrent = current?.card_id == cardId
        queue = Array(queue[..<index]) + queue[index...].filter { $0.card_id != cardId }
        if wasCurrent { advance() }
        refreshTodayCounts()
    }

    /// The deck being practised on its own, or nil for the usual mix of all decks.
    @Published private(set) var focusDeck: DeckSummary?

    /// Practise one deck: a fresh session from just that deck, until you leave it.
    func practice(deck: DeckSummary) {
        focusDeck = deck
        practiceRun = nil
        timesUp = false
        start()
    }

    /// Back to the normal mix of every deck.
    func leaveDeck() {
        focusDeck = nil
        practiceRun = nil
        timesUp = false
        start()
    }

    /// Cards practised outside the schedule: a whole deck, its learned or missed cards, or cards
    /// picked by hand. Ratings are logged but leave due dates alone (see the API's review/practice).
    struct PracticeRun: Equatable {
        enum Filter: String { case all, learned, missed }
        let title: String
        var folderId: String?? = nil     // a deck (nil inside: unfiled), or nil with cardIds
        var cardIds: [String]? = nil
        var filter: Filter = .all
    }
    @Published private(set) var practiceRun: PracticeRun?

    func practise(_ run: PracticeRun) {
        practiceRun = run
        focusDeck = nil
        timesUp = false
        start()
    }

    /// After a deal comes back empty: offer new cards past today's limits.
    enum AheadState { case none, offer, noneLeft }
    @Published private(set) var aheadState = AheadState.none

    func start() { deal(ahead: nil) }

    func practiceAhead(_ count: Int) { deal(ahead: count) }

    private func deal(ahead: Int?) {
        guard let token = AuthManager.shared.accessToken else { return }
        phase = .loading
        notice = nil
        aheadState = .none
        let focus: String?? = focusDeck.map { $0.folder_id }
        let run = practiceRun
        Task {
            do {
                let items: [ReviewItem]
                if let run {
                    items = try await PluckkAPI.shared.practiceSession(token: token, folderId: run.folderId, cardIds: run.cardIds, filter: run.filter.rawValue)
                } else {
                    items = try await PluckkAPI.shared.reviewSession(token: token, focus: focus, ahead: ahead)
                }
                queue = items
                index = 0
                reviewedCount = 0
                revealed = false
                editing = false
                history = []
                shownAt = Date()
                phase = items.isEmpty ? .done : .reviewing
                if items.isEmpty && run == nil { aheadState = ahead == nil ? .offer : .noneLeft }
                refreshTodayCounts()
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Keys

    private var keyMonitor: Any?
    private var clickMonitor: Any?

    /// Practice's keys (Space reveal, 1–5 rate, ← / Z back) handled before the rest of the app,
    /// so they still work after text on the card has been selected: a selectable text view
    /// takes keyboard focus and would otherwise swallow them. Button shortcuts wouldn't do: they'd
    /// also fire while typing in the assistant. Skipped while typing in an editor,
    /// during the "Good job" moment, and when Practice isn't on screen. Acting clears the
    /// selection.
    func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Esc hides the card's source, when it's showing.
            if let self, self.reading != nil, event.keyCode == 53 {
                self.closeReader()
                return nil
            }
            // ⌘+ / ⌘- / ⌘0: the size of the card's text.
            if let panel = PluckkPanel.shared, event.window === panel.hostWindow, AppState.shared.currentView == .practice {
                let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
                if mods == .command || mods == [.command, .shift] {
                    switch event.keyCode {
                    case 24, 69: CardTextScale.step(0.1); return nil
                    case 27, 78: CardTextScale.step(-0.1); return nil
                    case 29: CardTextScale.reset(); return nil
                    default: break
                    }
                }
            }
            // Backspace goes straight to the field being edited, so nothing on the way can lose it.
            if self?.editing == true, event.keyCode == 51,
               event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
               let tv = PluckkPanel.shared?.hostWindow.firstResponder as? NSTextView, tv.isEditable {
                tv.deleteBackward(nil)
                return nil
            }
            guard let self, AppState.shared.currentView == .practice,
                  let panel = PluckkPanel.shared, panel.isExpanded, event.window === panel.hostWindow,
                  !self.editing, !self.timesUp, case .reviewing = self.phase else { return event }
            // The assistant's box is the only editor left on this screen. While it's blank the
            // keys still belong to the card, so Space and 1–5 carry on after asking something.
            if let tv = panel.hostWindow.firstResponder as? NSTextView, tv.isEditable {
                let blank = tv.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let answering = self.current?.answersFirst == true && !self.revealed   // typing a range or blanks
                guard blank, !answering, [49, 18, 19, 20, 21, 23, 123].contains(event.keyCode) else { return event }
            }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard mods.isEmpty else { return event }

            var handled = true
            switch event.keyCode {
            case 49:                                    // Space
                if self.current?.answersFirst == true && !self.revealed { handled = false }   // the answer comes first
                else if !self.revealed { self.reveal() }
                else if let suggested = self.suggestedRating { self.rate(suggested) }
            case 36, 76:                                // Return: keep the suggested rating
                if self.revealed, let suggested = self.suggestedRating { self.rate(suggested) } else { handled = false }
            case 18, 19, 20, 21, 23:                    // 1–5
                guard self.revealed else { handled = false; break }
                let rating: ReviewRating = [18: .again, 19: .hard, 20: .good, 21: .easy, 23: .trivial][event.keyCode]!
                self.rate(rating)
            case 123, 6:                                // ← or Z
                self.undo()
            default:
                handled = false
            }
            guard handled else { return event }
            panel.hostWindow.makeFirstResponder(nil)    // drop any text selection
            return nil
        }
        // Clicking the card takes the keys back from the assistant's box.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            if let self, AppState.shared.currentView == .practice, !self.editing,
               let panel = PluckkPanel.shared, event.window === panel.hostWindow, panel.isAssistantOpen,
               event.locationInWindow.x < panel.hostWindow.frame.width - PluckkPanel.assistantWidth,
               let tv = panel.hostWindow.firstResponder as? NSTextView, tv.isEditable {
                panel.hostWindow.makeFirstResponder(nil)
            }
            return event
        }
    }

    func reveal() {
        guard current != nil, !revealed else { return }
        withAnimation(.easeOut(duration: 0.15)) { revealed = true }
        startSprintIfIdle()
    }

    private func startSprintIfIdle() {
        if !SessionTimer.shared.isRunning && !autoStartSuppressed && !timesUp {
            SessionTimer.shared.start()
        }
    }

    // MARK: Reading in context

    @Published private(set) var reading: ReaderPassage?

    /// Shows the card's source under it, or hides it if it's showing.
    func openReader(_ item: ReviewItem) {
        if reading?.cardId == item.card_id { reading = nil; return }
        guard let source = item.bookSource else { return }
        guard let opened = BookLibrary.passage(for: source, cardId: item.card_id) else {
            notice = "\(source.book) isn't in your bookshelf corpus."
            return
        }
        var passage = opened.passage
        passage.query = "\(item.question)\n\(item.answer)"
        reading = passage
        if !opened.found { notice = "Couldn't find this card's passage, so the chapter shows from its start." }
        let id = opened.passage.id
        Task {
            if let page = await opened.passage.withPage(), reading?.id == id { reading?.page = page }
        }
    }

    func closeReader() { reading = nil }

    // MARK: Number cards

    /// A number card's range against its answer, and the rating that suggests. Rating with any
    /// key or button records the range alongside.
    struct IntervalOutcome {
        let lower: Double
        let upper: Double
        let answer: Double
        let unit: String?
        let rating: ReviewRating
        let contained: Bool
    }
    @Published private(set) var outcome: IntervalOutcome?

    /// What a card's respond module scored, once it's answered.
    @Published private(set) var moduleResponse: ModuleResponse?

    /// The rating a range or a module suggests; Space or Return keeps it.
    var suggestedRating: ReviewRating? { outcome?.rating ?? moduleResponse?.rating }

    /// A written answer and what the checker made of it.
    @Published private(set) var written: (text: String, grade: PluckkAPI.WrittenGrade?)?

    func checkWritten(_ text: String, for item: ReviewItem) {
        guard current?.id == item.id, !revealed, !busy, let token = AuthManager.shared.accessToken else { return }
        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        busy = true
        notice = nil
        Task {
            defer { busy = false }
            do {
                let grade = try await PluckkAPI.shared.gradeWritten(token: token, cardId: item.card_id, response: answer)
                guard current?.id == item.id else { return }
                written = (answer, grade)
                moduleResponded(ModuleResponse(score: grade.score, summary: grade.feedback.isEmpty ? nil : grade.feedback), for: item)
            } catch {
                guard current?.id == item.id else { return }
                written = (answer, nil)
                notice = "Couldn't check it (\(error.localizedDescription)), so rate it yourself."
                withAnimation(.easeOut(duration: 0.15)) { revealed = true }
            }
        }
    }

    /// What was typed into a fill-in-the-blank card, judged blank by blank.
    @Published private(set) var typedResults: [TypedBlanks.Result]?

    func checkTyped(_ entries: [String], for item: ReviewItem) {
        guard current?.id == item.id, !revealed, let expected = item.typedBlanks else { return }
        let results = zip(expected, entries + Array(repeating: "", count: max(0, expected.count - entries.count))).map {
            TypedBlanks.Result(typed: $1.trimmingCharacters(in: .whitespaces), expected: $0, verdict: TypedBlanks.judge($1, $0))
        }
        typedResults = results
        moduleResponded(TypedBlanks.score(results), for: item)
    }

    func moduleResponded(_ response: ModuleResponse, for item: ReviewItem) {
        guard current?.id == item.id, !revealed else { return }
        moduleResponse = response
        withAnimation(.easeOut(duration: 0.15)) { revealed = true }
        startSprintIfIdle()
    }

    func lockInterval(_ lower: Double, _ upper: Double) {
        guard let item = current, item.isNumeric, !revealed, !busy, let token = AuthManager.shared.accessToken else { return }
        busy = true
        notice = nil
        Task {
            defer { busy = false }
            do {
                let score = try await PluckkAPI.shared.scoreInterval(token: token, cardId: item.card_id, lower: lower, upper: upper)
                guard current?.id == item.id else { return }
                outcome = IntervalOutcome(lower: score.lower, upper: score.upper, answer: score.answer, unit: score.unit,
                                          rating: score.rating, contained: score.contained)
                withAnimation(.easeOut(duration: 0.15)) { revealed = true }
                startSprintIfIdle()
            } catch {
                notice = "Couldn't check that range: \(error.localizedDescription)"
            }
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
                let result = try await PluckkAPI.shared.submitReview(token: token, item: item, rating: rating, responseMs: elapsed,
                                                                     interval: outcome.map { ($0.lower, $0.upper) },
                                                                     practice: practiceRun != nil,
                                                                     revealMs: revealedAt.map { Int($0.timeIntervalSince(shownAt) * 1000) })
                remember(.rating(eventId: result.event_id, item: item, index: index, wasAgain: rating == .again))
                if result.leech == true {
                    notice = "That card has slipped \(result.lapses ?? 4) times, so it's flagged as a leech. Rework it rather than drill it; the assistant can help."
                    for i in queue.indices where queue[i].card_id == item.card_id {
                        queue[i].tags = (queue[i].tags ?? []) + ["leech"]
                    }
                }
                SiteGate.shared.noteReview()
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
                refreshTodayCounts()
            } catch {
                notice = "Couldn't save that rating: \(error.localizedDescription)"
            }
        }
    }

    /// Go back one action (← or Z). An undone rating returns with its answer showing, so it can
    /// be re-rated straight away; an undone delete returns the card to the queue.
    func undo() {
        guard let last = history.last, !busy, !editing, let token = AuthManager.shared.accessToken else { return }
        busy = true
        notice = nil
        Task {
            defer { busy = false }
            do {
                switch last {
                case let .rating(eventId, item, at, wasAgain):
                    var restored = item
                    if let eventId, let fresh = try await PluckkAPI.shared.undoReview(token: token, eventId: eventId) { restored = fresh }
                    // An "again" re-queued a copy further on; drop that copy before putting the
                    // card back where it was.
                    if wasAgain, let copy = queue.indices.last(where: { $0 >= at && queue[$0].id == item.id }) {
                        queue.remove(at: copy)
                    }
                    let i = min(at, queue.count)
                    queue.insert(restored, at: i)
                    index = i
                    reviewedCount = max(0, reviewedCount - 1)
                    revealed = true
                case let .deletion(eventId, at, removed):
                    _ = try await PluckkAPI.shared.undoReview(token: token, eventId: eventId)
                    let i = min(at, queue.count)
                    queue.insert(contentsOf: removed, at: i)
                    index = i
                    revealed = false
                }
                history.removeLast()
                timesUp = false
                phase = .reviewing
                shownAt = Date()
                refreshTodayCounts()
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

    func saveEdit(question: String, answer: String, image: CardImageChange, number: CardNumberChange = .keep,
                  newCards: [SplitCard] = [], onCreated: @escaping (SplitCard) -> Void = { _ in }) {
        guard let item = current, editing, !busy, let token = AuthManager.shared.accessToken else { return }
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let a = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !a.isEmpty else { notice = "Question and answer can't be empty."; return }
        let trim = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
        let filled = newCards.filter { !trim($0.question).isEmpty || !trim($0.answer).isEmpty }
        guard filled.allSatisfy({ !trim($0.question).isEmpty && !trim($0.answer).isEmpty }) else {
            notice = "Each new card needs a question and an answer."
            return
        }
        let textChanged = q != item.question || a != item.answer
        var numberChanged = true
        if case .keep = number { numberChanged = false }
        if !textChanged, !numberChanged, filled.isEmpty, case .keep = image { editing = false; return }
        busy = true
        notice = nil
        Task {
            defer { busy = false }
            do {
                if textChanged {
                    try await PluckkAPI.shared.updateCard(token: token, cardId: item.card_id, question: q, answer: a)
                    for i in queue.indices where queue[i].card_id == item.card_id {
                        queue[i].question = q
                        queue[i].answer = a
                    }
                }
                if numberChanged {
                    var value: (value: Double, unit: String?)?
                    if case let .set(v, unit) = number { value = (v, unit) }
                    try await PluckkAPI.shared.setCardNumber(token: token, cardId: item.card_id, number: value)
                    for i in queue.indices where queue[i].card_id == item.card_id {
                        queue[i].answer_type = value == nil ? "text" : "numeric"
                        queue[i].numeric_answer = value?.value
                        queue[i].numeric_unit = value?.unit
                    }
                }
                try await saveImage(image, for: item, token: token)
                // Same deck and tags as the card it came from. Each is ticked off as it's made,
                // so a retry after a failure doesn't repeat it.
                let tags = (item.tags ?? []).filter { $0 != Rework.tag && $0 != ImageSide.questionTag }
                for split in filled {
                    _ = try await PluckkAPI.shared.createManualCard(token: token, question: trim(split.question), answer: trim(split.answer),
                                                                    folderId: item.folder?.id, tags: tags)
                    onCreated(split)
                }
                if !filled.isEmpty { refreshTodayCounts() }
                editing = false
            } catch {
                notice = "Couldn't save the edit: \(error.localizedDescription)"
            }
        }
    }

    private func saveImage(_ change: CardImageChange, for item: ReviewItem, token: String) async throws {
        var url: String?
        var tags = item.tags
        switch change {
        case .keep:
            return
        case .remove:
            try await PluckkAPI.shared.setCardImage(token: token, cardId: item.card_id, url: nil)
        case .replace(let image):
            guard let data = cardImageJPEG(image) else { throw APIError.serverError("That image couldn't be read.") }
            let stored = try await PluckkAPI.shared.uploadCardImage(token: token, cardId: item.card_id, imageData: data, mimeType: "image/jpeg")
            // A new image overwrites the same address; the version stops the old one showing.
            url = "\(stored)?v=\(Int(Date().timeIntervalSince1970))"
            // Art cards are on the question side by where they're stored, which the new image isn't.
            if item.imageIsQuestion, tags?.contains(ImageSide.questionTag) != true {
                tags = (tags ?? []) + [ImageSide.questionTag]
            }
            try await PluckkAPI.shared.setCardImage(token: token, cardId: item.card_id, url: url, tags: tags)
        }
        for i in queue.indices where queue[i].card_id == item.card_id {
            queue[i].image_url = url
            queue[i].tags = tags
        }
    }

    /// Flag (or unflag) the current card for later reworking; it stays in the session.
    func toggleRework() {
        guard let item = current, !busy, let token = AuthManager.shared.accessToken else { return }
        let tags = Rework.toggled(item.tags)
        busy = true
        notice = nil
        Task {
            defer { busy = false }
            do {
                try await PluckkAPI.shared.setTags(token: token, cardId: item.card_id, tags: tags)
                for i in queue.indices where queue[i].card_id == item.card_id { queue[i].tags = tags }
            } catch {
                notice = "Couldn't mark the card: \(error.localizedDescription)"
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
                if let eventId { remember(.deletion(eventId: eventId, index: index, removed: removed)) }
                advance()
                refreshTodayCounts()
            } catch {
                notice = "Couldn't delete the card: \(error.localizedDescription)"
            }
        }
    }

    private func advance() {
        editing = false
        revealed = false
        outcome = nil
        moduleResponse = nil
        typedResults = nil
        written = nil
        reading = nil
        shownAt = Date()
        if index >= queue.count { phase = .done }
        if celebrateAfterThisCard {
            celebrateAfterThisCard = false
            timesUp = true
        }
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
    @AppStorage(CardTextScale.key) private var textScale = 1.0
    @State private var editImage: NSImage?          // a new image, saved with the card
    @State private var editImageRemoved = false
    @State private var splitCards: [SplitCard] = []
    @State private var editIsNumber = false
    @State private var editNumber = ""
    @State private var editUnit = ""
    @AppStorage("extraNewCount") private var aheadCount = 5
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
        .overlay { if let zoomed { lightbox(zoomed) } }
        .onAppear {
            session.installKeyMonitor()
            session.startIfNeeded()
        }
        .onChange(of: session.current?.id) { _ in
            zoomed = nil
            confirmingDelete = false
            splitCards = []
        }
        .onChange(of: session.editing) { isEditing in
            if !isEditing { splitCards = [] }
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
            if imageShowing(item) && session.reading == nil {
                card(item)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 4)
                    .frame(maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 14) {
                            card(item)
                            if let reading = session.reading, reading.cardId == item.card_id {
                                SourceExcerpt(passage: reading) { session.closeReader() }
                                    .id(reading.id)
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                            ForEach($splitCards) { splitCardEditor($0).id($0.wrappedValue.id) }
                            if session.editing { addCardButton.id("addCard") }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 4)
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: splitCards.count) { _ in
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("addCard", anchor: .bottom) }
                    }
                }
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
            if let run = session.practiceRun {
                FocusDeckChip(title: run.title, note: "schedule unchanged") { session.leaveDeck() }
            } else if let focus = session.focusDeck {
                FocusDeckChip(title: focus.title) { session.leaveDeck() }
            } else if let deck = item.folder?.name {
                Text(deck.uppercased())
                    .font(.system(size: 10, weight: .semibold)).tracking(0.6)
                    .foregroundColor(PluckkTheme.accent)
            }
            if item.isLeech {
                Text("LEECH")
                    .font(.system(size: 10, weight: .semibold)).tracking(0.6)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(PluckkTheme.Dark.warning.opacity(0.14))
                    .foregroundColor(PluckkTheme.Dark.warning)
                    .cornerRadius(4)
                    .help("You keep forgetting this card. Rework it rather than drilling it: split it, add an example or a memory hook. The assistant can help.")
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
                .help("Back (← or Z)")
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
        .padding(.top, 50)      // clear of the flag / edit / delete icons
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, minHeight: 160, maxHeight: imageShowing(item) ? .infinity : nil)
        .background(cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(rule.opacity(0.7), lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            if !session.editing { cardActions.padding(10) }
        }
        .overlay(alignment: .topLeading) {
            // The book a card comes from, small in the corner rather than in the question.
            if !session.editing, let book = item.bookSource {
                Text(book.shortTitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(mutedText)
                    .lineLimit(1)
                    .padding(.leading, 18).padding(.top, 16)
                    .help(book.book + (book.chapter.map { " · \($0)" } ?? ""))
            }
        }
        .shadow(color: Color.black.opacity(isDark ? 0.55 : 0.10), radius: 12, y: 4)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !session.editing, !(item.answersFirst && !session.revealed) else { return }
            PluckkPanel.shared?.hostWindow.makeFirstResponder(nil)   // a click on the card clears a selection
            session.reveal()
        }
        .id(item.id)
    }

    /// Whether the card's image is on screen now (see ReviewItem.imageIsQuestion).
    private func imageShowing(_ item: ReviewItem) -> Bool {
        item.image_url != nil && !session.editing && (session.revealed || item.imageIsQuestion)
    }

    private func cardContent(_ item: ReviewItem) -> some View {
        VStack(spacing: 16) {
            Text(cardMarkdown(item.shownQuestion))
                .textSelection(.enabled)
                .font(.system(size: fittedSize(item.question), weight: .semibold))
                .foregroundColor(primaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            if !session.revealed, item.imageIsQuestion, let url = item.image_url.flatMap(URL.init(string:)) {
                cardImage(url)
            }

            ForEach(Array((item.modules?.prompt ?? []).enumerated()), id: \.offset) { _, module in
                ModuleSlotView(module: module, slot: .prompt)
            }
            if let module = item.respondModule {
                ModuleSlotView(module: module, slot: .respond, revealed: session.revealed) {
                    session.moduleResponded($0, for: item)
                }
            }

            if item.isWritten && !session.revealed {
                WrittenAnswerEntry(busy: session.busy) { session.checkWritten($0, for: item) }
                    .padding(.top, 4)
            }

            if let blanks = item.typedBlanks, !session.revealed {
                TypedBlanksEntry(count: blanks.count) { session.checkTyped($0, for: item) }
                    .padding(.top, 4)
            }

            if item.isNumeric && !session.revealed {
                IntervalEntry(unit: item.numeric_unit, busy: session.busy) { session.lockInterval($0, $1) }
                    .padding(.top, 6)
            }

            if session.revealed {
                if let outcome = session.outcome { IntervalReveal(outcome: outcome).padding(.top, 4) }
                if let typed = session.typedResults { TypedBlanksReveal(results: typed) }
                if let written = session.written { WrittenAnswerReveal(text: written.text, grade: written.grade) }
                if let response = session.moduleResponse, let summary = response.summary {
                    Text(summary)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(response.score >= 0.7 ? PluckkTheme.Dark.success : Color(hex: "e5a14b"))
                }
                Rectangle().fill(rule).frame(height: 1)
                Text(cardMarkdown(item.answer))
                    .textSelection(.enabled)
                    .font(.system(size: fittedSize(item.answer) - 1))
                    .foregroundColor(answerText)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
                ForEach(Array((item.modules?.reveal ?? []).enumerated()), id: \.offset) { _, module in
                    ModuleSlotView(module: module, slot: .reveal, revealed: true)
                }
                if let url = item.image_url.flatMap(URL.init(string:)) {
                    cardImage(url)
                }
                if let book = item.bookSource {
                    Button(action: { session.openReader(item) }) {
                        HStack(spacing: 5) {
                            Image(systemName: "book").font(.system(size: 10))
                            Text(session.reading?.cardId == item.card_id ? "Hide the source" : "Read in context · \(book.book)")
                        }
                        .font(.system(size: 11))
                        .foregroundColor(mutedText)
                    }
                    .buttonStyle(.plain)
                    .help("Open the passage this card came from, in its chapter")
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
                if let id = session.current?.card_id { CopyCardIDButton(cardId: id) }
                let marked = session.current?.isMarkedForRework == true
                CardIconButton(systemName: marked ? "flag.fill" : "flag",
                               help: marked ? "Marked for rework (click to unmark)" : "Mark for rework",
                               hoverTint: PluckkTheme.Dark.warning,
                               tint: marked ? PluckkTheme.Dark.warning : nil) {
                    session.toggleRework()
                }
                .disabled(session.busy)
                CardIconButton(systemName: "pencil",
                               help: session.canEditCurrent ? "Edit card" : "Two-way and list cards are edited in the web app") {
                    beginEditing()
                }
                .disabled(!session.canEditCurrent || session.busy)
                CardIconButton(systemName: "trash", help: "Delete card", hoverTint: Color(hex: "e5534b")) {
                    confirmingDelete = true
                }
                .disabled(session.busy)
            }
        }
    }

    private func beginEditing() {
        editQuestion = session.current?.question ?? ""
        editAnswer = session.current?.answer ?? ""
        editImage = nil
        editImageRemoved = false
        let item = session.current
        editIsNumber = item?.isNumeric == true
        editNumber = item?.numeric_answer.map(NumberText.format) ?? ""
        editUnit = item?.numeric_unit ?? ""
        session.beginEdit()
    }

    /// Below the card while editing: opens a blank card, to split this one in two or more.
    private var addCardButton: some View {
        Button(action: { splitCards.append(SplitCard()) }) {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(mutedText)
                .frame(width: 30, height: 30)
                .overlay(Circle().stroke(rule, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Add a new card, to split this one")
    }

    private func splitCardEditor(_ split: Binding<SplitCard>) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            CardTextField(label: "Question", text: split.question, prominent: true, minLines: 2, autofocus: true)
            CardTextField(label: "Answer", text: split.answer, minLines: 3)
        }
        .padding(.horizontal, 24)
        .padding(.top, 34)
        .padding(.bottom, 24)
        .background(cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(rule.opacity(0.7), lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            let id = split.wrappedValue.id
            CardIconButton(systemName: "xmark", help: "Remove this new card") {
                splitCards.removeAll { $0.id == id }
            }
            .padding(8)
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardTextField(label: "Question", text: $editQuestion, prominent: true, minLines: 3, autofocus: true)
            if editIsNumber {
                numberFields
                CardTextField(label: "Explanation", text: $editAnswer, minLines: 3)
            } else {
                CardTextField(label: "Answer", text: $editAnswer, minLines: 4)
            }
            Toggle("The answer is a number (answered with a 95% range)", isOn: $editIsNumber)
                .font(.system(size: 12))
            imageEditor
        }
    }

    /// A number card's answer: the value and unit its 95% range is checked against.
    private var numberFields: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("ANSWER").font(.system(size: 10, weight: .semibold)).tracking(0.7).foregroundColor(.secondary)
            HStack(spacing: 10) {
                numberField("e.g. 46 or 2.5 billion", $editNumber, width: 220)
                numberField("unit, e.g. MJ/kg or %", $editUnit, width: 180)
                if !editNumber.isEmpty && NumberText.parse(editNumber) == nil {
                    Text("Not a number").font(.system(size: 11)).foregroundColor(PluckkTheme.Dark.error)
                }
            }
        }
    }

    private func numberField(_ prompt: String, _ text: Binding<String>, width: CGFloat) -> some View {
        TextField(prompt, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 17, weight: .semibold).monospacedDigit())
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(width: width)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(isDark ? 0.035 : 0.025)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(rule, lineWidth: 1))
    }

    /// The explanation usually states the number too ("About 12,000 Wh/kg."): when the number
    /// changes, that figure follows, if it's there as it was.
    private func explanationFollowing(_ change: CardNumberChange) -> String {
        guard case let .set(value, unit) = change, let item = session.current, let old = item.numeric_answer else { return editAnswer }
        let oldUnit = item.numeric_unit ?? ""
        let newText = NumberText.withUnit(value, unit)
        let plainOld = old.rounded() == old ? String(Int(old)) : String(old)
        for figure in [NumberText.format(old), plainOld] {
            for written in oldUnit.isEmpty ? [figure] : [figure + " " + oldUnit, figure + oldUnit] {
                if editAnswer.contains(written) { return editAnswer.replacingOccurrences(of: written, with: newText) }
            }
        }
        return editAnswer
    }

    /// nil while the number can't be read, so Save waits for it.
    private var editNumberChange: CardNumberChange? {
        let item = session.current
        let unit = editUnit.trimmingCharacters(in: .whitespaces)
        guard editIsNumber else { return item?.isNumeric == true ? .clear : .keep }
        guard let value = NumberText.parse(editNumber) else { return nil }
        if item?.isNumeric == true, item?.numeric_answer == value, (item?.numeric_unit ?? "") == unit { return .keep }
        return .set(value, unit.isEmpty ? nil : unit)
    }

    private var editImageURL: URL? {
        editImageRemoved ? nil : session.current?.image_url.flatMap(URL.init(string:))
    }

    /// Replace or remove the card's image. Nothing changes until Save.
    private var imageEditor: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("IMAGE").font(.system(size: 10, weight: .semibold)).tracking(0.7).foregroundColor(.secondary)
            if let editImage {
                Image(nsImage: editImage).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else if let url = editImageURL {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fit)
                } placeholder: {
                    ProgressView().controlSize(.small)
                }
                .frame(maxHeight: 140)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            HStack(spacing: 10) {
                Button(action: pasteEditImage) {
                    HStack(spacing: 6) {
                        Image(systemName: "photo.on.rectangle")
                        Text(editImage != nil || editImageURL != nil ? "Replace from clipboard" : "Paste image")
                    }
                }
                .buttonStyle(QuietButtonStyle())
                Text("or drop an image here").font(.system(size: 11)).foregroundColor(.secondary)
                Spacer()
                if editImage != nil || editImageURL != nil {
                    Button("Remove") {
                        editImage = nil
                        editImageRemoved = true
                    }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundColor(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
        .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
            loadDroppedImage(providers) { editImage = $0 }
        }
    }

    private func pasteEditImage() {
        if let image = SelectionReader().getClipboardImage() {
            editImage = image
        } else {
            session.notice = "No image on the clipboard. Take a screenshot with ⌃⇧⌘4 (to clipboard), then paste."
        }
    }

    private var editImageChange: CardImageChange {
        if let editImage { return .replace(editImage) }
        return editImageRemoved ? .remove : .keep
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
                Button(action: {
                    guard let number = editNumberChange else { session.notice = "The number isn't readable."; return }
                    session.saveEdit(question: editQuestion, answer: explanationFollowing(number), image: editImageChange, number: number,
                                     newCards: splitCards) { made in
                        splitCards.removeAll { $0.id == made.id }
                    }
                }) {
                    HStack(spacing: 6) {
                        Text(splitCards.isEmpty ? "Save" : "Save all")
                        Text("⌘↩").font(.system(size: 11, weight: .medium)).opacity(0.6)
                    }
                }
                .buttonStyle(PillButtonStyle(prominent: true))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(session.busy)
            }
        } else if session.revealed {
            VStack(spacing: 8) {
                if let suggested = session.suggestedRating {
                    Text("\(session.outcome != nil ? "Your range" : "Your answer") suggests \(suggested.title). Space or ↩ keeps it, or pick another.")
                        .font(.system(size: 12))
                        .foregroundColor(mutedText)
                }
                HStack(spacing: 8) {
                    ForEach(ReviewRating.allCases, id: \.self) { rating in
                        RatingButton(rating: rating, interval: item.previews.label(for: rating),
                                     suggested: session.suggestedRating == rating) { session.rate(rating) }
                            .disabled(session.busy)
                    }
                }
            }
        } else if item.respondModule != nil || item.typedBlanks != nil || item.isWritten {
            Button("Show the answer") { session.reveal() }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(mutedText)
        } else if item.isNumeric {
            Button("Show the answer without a range") { session.reveal() }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(mutedText)
                .frame(maxWidth: .infinity)
        } else {
            Button(action: { session.reveal() }) {
                HStack(spacing: 8) {
                    Text("Show answer")
                    KeyCap("space")
                }
            }
            .buttonStyle(QuietButtonStyle())
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
                if let run = session.practiceRun {
                    FocusDeckChip(title: run.title, note: "schedule unchanged") { session.leaveDeck() }
                } else if let focus = session.focusDeck {
                    FocusDeckChip(title: focus.title) { session.leaveDeck() }
                }
                Text(session.practiceRun != nil ? (session.reviewedCount > 0 ? "Practice done" : "Nothing to practise here")
                     : session.aheadState == .noneLeft ? "No new cards left" : session.reviewedCount > 0 ? "Session done" : (session.focusDeck != nil ? "Nothing due in this deck" : "Nothing due right now"))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(primaryText)
                if session.reviewedCount > 0 {
                    Text("\(session.reviewedCount) review\(session.reviewedCount == 1 ? "" : "s")")
                        .font(.system(size: 13))
                        .foregroundColor(mutedText)
                }
                if offerExtra {
                    HStack(spacing: 8) {
                        Text("Add")
                        TextField("", value: $aheadCount, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.center)
                            .frame(width: 46)
                            .onSubmit(practiceAhead)
                        Stepper("", value: $aheadCount, in: 1...100).labelsHidden()
                        Text(aheadCount == 1 ? "new card for today?" : "new cards for today?")
                    }
                    .font(.system(size: 13))
                    .foregroundColor(mutedText)
                }
                HStack(spacing: 10) {
                    if session.canUndo {
                        Button("Undo last") { session.undo() }.buttonStyle(PillButtonStyle(prominent: false))
                    }
                    if session.practiceRun != nil {
                        Button("Practise again") { session.start() }.buttonStyle(PillButtonStyle(prominent: false))
                        Button("Back to the schedule") { session.leaveDeck() }.buttonStyle(PillButtonStyle(prominent: true))
                    } else if offerExtra {
                        Button("Add them", action: practiceAhead).buttonStyle(PillButtonStyle(prominent: true))
                    } else {
                        Button("Start another") { session.start() }.buttonStyle(PillButtonStyle(prominent: true))
                    }
                }
                .padding(.top, 4)
                SiteGateOffer(dayDone: dayDone).padding(.top, 6)
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

    /// Done for the day: nothing due and no new cards left under today's limits (or, for a single
    /// deck, nothing more it could deal). Extra new cards then come from the decks in the shares
    /// set in Statistics.
    private var offerExtra: Bool {
        if session.aheadState == .offer { return true }
        guard session.aheadState == .none, session.focusDeck == nil, let counts = session.todayCounts else { return false }
        return counts.review == 0 && counts.learn == 0
    }

    /// Nothing due and no new cards left under today's limits, across every deck.
    private var dayDone: Bool {
        guard session.practiceRun == nil, session.focusDeck == nil, let counts = session.todayCounts else { return false }
        return counts.review == 0 && counts.learn == 0
    }

    private func practiceAhead() {
        session.practiceAhead(min(max(aheadCount, 1), 100))
    }

    /// Type that fits its content: short prompts large, long ones step down (as in the web app).
    private func fittedSize(_ text: String) -> CGFloat {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = t.count
        // A character or two of Chinese or Japanese, shown on its own: big enough to read its strokes.
        let glyphs = n > 0 && n <= 3 && t.unicodeScalars.allSatisfy { (0x3400...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) }
        let base: CGFloat = glyphs ? 72 : n <= 60 ? 22 : n <= 140 ? 19 : n <= 320 ? 16 : 14
        return base * CGFloat(textScale > 0 ? textScale : 1)
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

/// Copies a reference to the card ("pluckk card <uuid>") so it can be pasted into a chat with
/// an agent, which looks it up with the pluckk-cards skill (`pluckk.py card <id>`). The icon
/// turns into a check for a moment to confirm.
struct CopyCardIDButton: View {
    let cardId: String
    @State private var copied = false

    var body: some View {
        CardIconButton(systemName: copied ? "checkmark" : "number",
                       help: "Copy card ID",
                       tint: copied ? PluckkTheme.Dark.success : nil) {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString("pluckk card \(cardId)", forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        }
    }
}

/// "Practising <deck> ✕": shown while one deck is being practised; ✕ returns to the mix.
struct FocusDeckChip: View {
    let title: String
    var note: String? = nil
    let onLeave: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text("PRACTISING")
                .font(.system(size: 9, weight: .semibold)).tracking(0.6)
                .foregroundColor(.secondary)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(PluckkTheme.accent)
                .lineLimit(1)
            if let note {
                Text("· \(note)").font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
            }
            Button(action: onLeave) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    .foregroundColor(Color.primary.opacity(hovering ? 0.8 : 0.45))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("Back to all decks")
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(PluckkTheme.accent.opacity(0.12)))
    }
}

/// A small icon button in the card's top-right corner.
struct CardIconButton: View {
    let systemName: String
    let help: String
    var hoverTint: Color? = nil
    /// A colour at rest (e.g. a set flag); otherwise muted until hovered.
    var tint: Color? = nil
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(hovering && isEnabled ? (hoverTint ?? Color.primary.opacity(0.8)) : (tint ?? Color.primary.opacity(0.35)))
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
    /// The rating a number card's range suggests.
    var suggested = false
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
        case .trivial: return Color(hex: "a371f7")
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
                    .stroke(suggested ? tint : hovering ? tint.opacity(0.8) : (isDark ? PluckkTheme.Dark.cardBorder : PluckkTheme.Light.cardBorder),
                            lineWidth: suggested ? 2 : 1)
            )
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

