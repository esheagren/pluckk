import SwiftUI
import AppKit

// MARK: - App State

enum CapturedContent: Equatable {
    case text(String)
    case image(NSImage)

    static func == (lhs: CapturedContent, rhs: CapturedContent) -> Bool {
        switch (lhs, rhs) {
        case (.text(let l), .text(let r)): return l == r
        case (.image(let l), .image(let r)): return l === r
        default: return false
        }
    }
}

/// The panel's three views: practice (native review; ⌘⌘ with nothing selected), capture →
/// generate, and settings.
/// Browsing and deck management live in the web app (pluckk.app).
enum PanelView {
    case generate
    case practice
    case settings
}

struct SourceContext {
    let appName: String
    let windowTitle: String

    var displayString: String {
        windowTitle.isEmpty ? appName : "\(appName) - \(windowTitle)"
    }
}

class AppState: ObservableObject {
    static let shared = AppState()

    @Published var isAuthenticated = false
    @Published var user: User?
    @Published var currentView: PanelView = .generate

    // Content capture
    @Published var capturedContent: CapturedContent?
    @Published var sourceContext: SourceContext?

    // Card generation
    @Published var isGenerating = false
    @Published var generatedCards: [GeneratedCard] = []
    @Published var selectedCardIndices: Set<Int> = []
    @Published var generationError: String?

    // Decks (Pluckk folders)
    @Published var decks: [Deck] = []
    @Published var selectedDeckId: String?

    // Settings
    @Published var mochiEnabled = false
    @Published var mochiApiKey: String?
    @Published var mochiDeckId: String?

    private init() {}

    func reset() {
        capturedContent = nil
        sourceContext = nil
        isGenerating = false
        generatedCards = []
        selectedCardIndices = []
        generationError = nil
    }
}

// MARK: - Card Models

struct QAPair: Codable {
    let question: String
    let answer: String
}

struct GeneratedCard: Identifiable {
    let id = UUID()
    var style: CardStyle
    var question: String
    var answer: String
    var isSelected: Bool = true
    var isEditing: Bool = false

    // Bidirectional cards (qa_bidirectional)
    var forward: QAPair?
    var reverse: QAPair?

    // List cards (cloze_list)
    var listName: String?
    var items: [String]?
    var prompts: [QAPair]?

    /// Number of cards this will expand to when saved (can be 0 for invalid cards)
    var expandedCardCount: Int {
        switch style {
        case .qa_bidirectional:
            return (forward != nil ? 1 : 0) + (reverse != nil ? 1 : 0)
        case .cloze_list:
            return prompts?.count ?? 0
        default:
            return 1
        }
    }
}

enum CardStyle: String, Codable {
    case qa
    case qa_bidirectional
    case cloze
    case cloze_list
    case explanation
    case application
    case diagram

    var displayName: String {
        switch self {
        case .qa: return "Q&A"
        case .qa_bidirectional: return "Bidirectional"
        case .cloze: return "Cloze"
        case .cloze_list: return "List Cloze"
        case .explanation: return "Explanation"
        case .application: return "Application"
        case .diagram: return "Diagram"
        }
    }
}

// MARK: - User Models

struct User {
    let id: String
    let email: String
    let displayName: String?
    let mochiApiKey: String?
    let mochiDeckId: String?
}

struct Deck: Identifiable {
    let id: String
    let name: String
}
