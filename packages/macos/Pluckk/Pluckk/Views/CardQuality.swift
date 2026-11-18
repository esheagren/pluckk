import SwiftUI

// Judging a card as a spaced-repetition question, while reviewing it: a four-rung quality, markers
// for what's wrong with it, the rework flag, and a note. Quality and markers are plain card tags
// ("quality:gold", "issue:wordy"), so they filter and collect like any tag and every change is in
// the card's history beside the wording it was made about; the note is stored on the card.
// Together they are the labelled set that card generation is measured against.

/// How good the card is. The rungs line up with the tiers used in published prompt-quality work
/// (ready as it stands / needs polish / needs rewriting), with Gold above them for exemplars.
enum CardQuality: String, CaseIterable, Identifiable {
    case gold, good, passable, bad

    static let prefix = "quality:"
    var id: String { rawValue }
    var tag: String { Self.prefix + rawValue }

    var title: String {
        switch self {
        case .gold: return "Gold"
        case .good: return "Good"
        case .passable: return "Passable"
        case .bad: return "Bad"
        }
    }

    var help: String {
        switch self {
        case .gold: return "An example of what a card should be"
        case .good: return "Fine as it is"
        case .passable: return "Worth keeping, but needs a polish"
        case .bad: return "Needs rewriting, or isn't worth asking"
        }
    }

    var symbol: String {
        switch self {
        case .gold: return "star.fill"
        case .good: return "hand.thumbsup.fill"
        case .passable: return "minus.circle.fill"
        case .bad: return "hand.thumbsdown.fill"
        }
    }

    var tint: Color {
        switch self {
        case .gold: return PluckkTheme.accent
        case .good: return PluckkTheme.Dark.success
        case .passable: return Color.secondary
        case .bad: return PluckkTheme.Dark.error
        }
    }

    static func of(_ tags: [String]?) -> CardQuality? {
        (tags ?? []).lazy.compactMap { $0.hasPrefix(prefix) ? CardQuality(rawValue: String($0.dropFirst(prefix.count))) : nil }.first
    }
}

/// What's wrong with a card. Any number can be set.
enum CardIssue: String, CaseIterable, Identifiable {
    case multipleAnswers = "multiple-answers"
    case notAtomic = "not-atomic"
    case lacksContext = "lacks-context"
    case shallow
    case wordy
    case offTarget = "off-target"
    case wrong

    static let prefix = "issue:"
    var id: String { rawValue }
    var tag: String { Self.prefix + rawValue }

    var title: String {
        switch self {
        case .multipleAnswers: return "No one clear answer"
        case .notAtomic: return "More than one fact"
        case .lacksContext: return "Needs its source to make sense"
        case .shallow: return "Shallow"
        case .wordy: return "Wordy"
        case .offTarget: return "Not the interesting part"
        case .wrong: return "Wrong"
        }
    }

    var help: String {
        switch self {
        case .multipleAnswers: return "Sprawling: several different answers would be fair, so it's hard to say whether you knew it"
        case .notAtomic: return "Asks for several things at once; it should be split"
        case .lacksContext: return "Doesn't stand on its own: you'd need the book or the page to know what it means"
        case .shallow: return "Can be answered by matching words, without understanding"
        case .wordy: return "Longer than it needs to be"
        case .offTarget: return "Asks about something that isn't what matters in the source"
        case .wrong: return "The answer is inaccurate"
        }
    }
}

/// A card's quality, issues and rework flag, read from and written back to its tags.
struct CardAssessment: Equatable {
    var quality: CardQuality?
    var issues: Set<CardIssue> = []
    var rework = false

    init(tags: [String]?) {
        let tags = tags ?? []
        quality = CardQuality.of(tags)
        issues = Set(tags.compactMap { $0.hasPrefix(CardIssue.prefix) ? CardIssue(rawValue: String($0.dropFirst(CardIssue.prefix.count))) : nil })
        rework = tags.contains(Rework.tag)
    }

    var isEmpty: Bool { quality == nil && issues.isEmpty && !rework }

    /// The card's other tags, then these.
    func applied(to tags: [String]?) -> [String] {
        var out = (tags ?? []).filter { !$0.hasPrefix(CardQuality.prefix) && !$0.hasPrefix(CardIssue.prefix) && $0 != Rework.tag }
        if let quality { out.append(quality.tag) }
        out += CardIssue.allCases.filter(issues.contains).map(\.tag)
        if rework { out.append(Rework.tag) }
        return out
    }
}

/// The card's rating, in its corner: a star until it's rated, then the rating's own mark. A click
/// opens the scale, the issue markers, the rework flag and the note.
struct CardQualityButton: View {
    let tags: [String]?
    let note: String?
    let onTags: ([String]) -> Void
    let onNote: (String) -> Void
    @State private var open = false

    private var assessment: CardAssessment { CardAssessment(tags: tags) }

    var body: some View {
        let a = assessment
        let hasNote = !(note ?? "").isEmpty
        CardIconButton(systemName: a.quality?.symbol ?? (a.rework || !a.issues.isEmpty ? "flag.fill" : hasNote ? "text.bubble.fill" : "star"),
                       help: a.quality.map { "Rated \($0.title.lowercased()): click to change, mark an issue or add a note" }
                           ?? "Rate this card, mark what's wrong with it, or add a note",
                       hoverTint: PluckkTheme.accent,
                       tint: a.quality?.tint ?? (a.rework || !a.issues.isEmpty ? PluckkTheme.Dark.warning : hasNote ? Color.secondary : nil)) {
            open.toggle()
        }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            CardQualityPanel(tags: tags, note: note ?? "", onTags: onTags, onNote: onNote)
        }
    }
}

private struct CardQualityPanel: View {
    let tags: [String]?
    let onTags: ([String]) -> Void
    let onNote: (String) -> Void
    @State private var assessment: CardAssessment
    @State private var noteText: String
    private let savedNote: String

    init(tags: [String]?, note: String, onTags: @escaping ([String]) -> Void, onNote: @escaping (String) -> Void) {
        self.tags = tags
        self.onTags = onTags
        self.onNote = onNote
        savedNote = note
        _assessment = State(initialValue: CardAssessment(tags: tags))
        _noteText = State(initialValue: note)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            label("HOW GOOD IS THIS CARD?")
            HStack(spacing: 6) {
                ForEach(CardQuality.allCases) { q in
                    let on = assessment.quality == q
                    Button(action: { assessment.quality = on ? nil : q; saveTags() }) {
                        HStack(spacing: 5) {
                            Image(systemName: q.symbol).font(.system(size: 10))
                            Text(q.title).font(.system(size: 12, weight: on ? .semibold : .regular))
                        }
                        .foregroundColor(on ? q.tint : .primary.opacity(0.75))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(on ? q.tint.opacity(0.16) : Color.primary.opacity(0.06)))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(q.help)
                }
            }
            label("WHAT'S WRONG WITH IT")
            FlowLayout(spacing: 6) {
                ForEach(CardIssue.allCases) { issue in
                    let on = assessment.issues.contains(issue)
                    Button(action: {
                        if on { assessment.issues.remove(issue) } else { assessment.issues.insert(issue) }
                        saveTags()
                    }) {
                        Text(issue.title).font(.system(size: 11, weight: on ? .semibold : .regular))
                            .foregroundColor(on ? PluckkTheme.Dark.warning : .primary.opacity(0.75))
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(Capsule().fill(on ? PluckkTheme.Dark.warning.opacity(0.16) : Color.primary.opacity(0.06)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(issue.help)
                }
            }
            Toggle(isOn: Binding(get: { assessment.rework }, set: { assessment.rework = $0; saveTags() })) {
                Text("Flag for rework").font(.system(size: 12))
            }
            .toggleStyle(.checkbox)
            .help("Collects under Flagged in Decks, to fix later")
            label("NOTE")
            TextField("Why it's good, or what to change", text: $noteText, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 12)).lineLimit(2...6)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
                .onSubmit(saveNote)
        }
        .padding(14)
        .frame(width: 330)
        .onDisappear(perform: saveNote)
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundColor(.secondary)
    }

    private func saveTags() { onTags(assessment.applied(to: tags)) }

    private func saveNote() {
        let text = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text != savedNote.trimmingCharacters(in: .whitespacesAndNewlines) { onNote(text) }
    }
}
