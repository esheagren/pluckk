import Foundation
import AppKit

/// Thin client over the Pluckk API. Every call carries the bearer token; a 401
/// signs the user out. No scheduling or storage logic lives here any more —
/// the server owns cards, folders, review state and Mochi sync.
class PluckkAPI {
    static let shared = PluckkAPI()

    private let baseURL = Config.backendURL
    private let timeout: TimeInterval = 60

    private init() {}

    // MARK: - User

    struct UserMeResponse: Decodable {
        let user: UserInfo
        let settings: SettingsInfo?

        struct UserInfo: Decodable {
            let id: String
            let email: String?
            let displayName: String?
            let avatarUrl: String?
        }
        struct SettingsInfo: Decodable {
            let mochiApiKey: String?
            let mochiDeckId: String?
        }
    }

    func fetchUser(token: String) async throws -> User {
        let data = try await send(token: token, method: "GET", path: "/api/user/me")
        let me = try JSONDecoder().decode(UserMeResponse.self, from: data)
        return User(
            id: me.user.id,
            email: me.user.email ?? "",
            displayName: me.user.displayName,
            mochiApiKey: me.settings?.mochiApiKey,
            mochiDeckId: me.settings?.mochiDeckId
        )
    }

    /// PATCH /api/user/me — keys are camelCase (`mochiApiKey`, `mochiDeckId`, `displayName`).
    func updateUser(token: String, updates: [String: Any]) async throws {
        _ = try await send(token: token, method: "PATCH", path: "/api/user/me", json: updates)
    }

    func revokeToken(_ token: String) async {
        _ = try? await send(token: token, method: "DELETE", path: "/api/v1/auth/token")
    }

    // MARK: - Card Generation

    struct GenerateCardsRequest: Encodable {
        let selection: String
        let context: String
        let url: String
        let title: String
        let focusText: String?
    }

    struct GenerateCardsResponse: Decodable {
        let cards: [APICard]
    }

    /// API card format - supports multiple card styles from the backend
    struct APICard: Decodable {
        let style: String
        let question: String?
        let answer: String?
        let forward: QAPair?
        let reverse: QAPair?
        let list_name: String?
        let items: [String]?
        let prompts: [QAPair]?
        let diagram_prompt: String?

        struct QAPair: Decodable {
            let question: String
            let answer: String
        }

        /// Convert API card to GeneratedCard, preserving structure for bidirectional/list types.
        func toGeneratedCard() -> GeneratedCard {
            let cardStyle = CardStyle(rawValue: style) ?? .qa
            switch style {
            case "qa_bidirectional":
                if forward == nil && reverse == nil, let q = question, let a = answer {
                    return GeneratedCard(style: .qa, question: q, answer: a)
                }
                let fwdPair: Pluckk.QAPair? = forward.map { Pluckk.QAPair(question: $0.question, answer: $0.answer) }
                let revPair: Pluckk.QAPair? = reverse.map { Pluckk.QAPair(question: $0.question, answer: $0.answer) }
                return GeneratedCard(
                    style: .qa_bidirectional,
                    question: forward?.question ?? "",
                    answer: forward?.answer ?? "",
                    forward: fwdPair,
                    reverse: revPair
                )
            case "cloze_list":
                if prompts == nil || prompts?.isEmpty == true, let q = question, let a = answer {
                    return GeneratedCard(style: .cloze, question: q, answer: a)
                }
                let qaPairs: [Pluckk.QAPair]? = prompts?.map { Pluckk.QAPair(question: $0.question, answer: $0.answer) }
                return GeneratedCard(
                    style: .cloze_list,
                    question: list_name ?? "List",
                    answer: items?.joined(separator: ", ") ?? "",
                    listName: list_name,
                    items: items,
                    prompts: qaPairs
                )
            default:
                return GeneratedCard(style: cardStyle, question: question ?? "", answer: answer ?? "")
            }
        }
    }

    func generateCards(token: String, request: GenerateCardsRequest) async throws -> [GeneratedCard] {
        let body = try JSONEncoder().encode(request)
        let data = try await send(token: token, method: "POST", path: "/api/generate-cards", body: body)
        let apiResponse = try JSONDecoder().decode(GenerateCardsResponse.self, from: data)
        return apiResponse.cards.map { $0.toGeneratedCard() }
    }

    func generateCardsFromImage(token: String, imageData: Data, context: SourceContext?) async throws -> [GeneratedCard] {
        let body: [String: Any] = [
            "imageData": imageData.base64EncodedString(),
            "mimeType": "image/png",
            "context": context?.displayString ?? ""
        ]
        let data = try await send(token: token, method: "POST", path: "/api/generate-cards-from-image", json: body)
        let apiResponse = try JSONDecoder().decode(GenerateCardsResponse.self, from: data)
        return apiResponse.cards.map { $0.toGeneratedCard() }
    }

    // MARK: - Save Card

    struct SendCardResponse {
        let success: Bool
        let cardId: String?
        let mochiCardId: String?
    }

    private struct CardRow: Decodable { let id: String }

    /// The card as the core engine stores it: one spec, components scheduled server-side.
    private func spec(for card: GeneratedCard) throws -> [String: Any] {
        switch card.style {
        case .qa_bidirectional:
            guard let f = card.forward, let r = card.reverse else { throw APIError.serverError("Bidirectional card is missing a direction") }
            return ["style": "qa_bidirectional",
                    "forward": ["question": f.question, "answer": f.answer],
                    "reverse": ["question": r.question, "answer": r.answer]]
        case .cloze_list:
            let prompts = (card.prompts ?? []).map { ["question": $0.question, "answer": $0.answer] }
            guard !prompts.isEmpty else { throw APIError.serverError("List card has no prompts") }
            return ["style": "cloze_list", "listName": card.listName ?? card.question, "items": card.items ?? [], "prompts": prompts]
        default:
            return ["style": card.style.rawValue, "question": card.question, "answer": card.answer]
        }
    }

    /// Save a card via POST /api/v1/cards; optionally mirror it to Mochi via the API.
    /// Provenance for a native app: identifier "app:<app>/<window title>", containerTitle = app, title = window.
    func sendCard(token: String, card: GeneratedCard, sourceUrl: String, sourceTitle: String?, appName: String? = nil, selection: String? = nil, deckId: String?) async throws -> SendCardResponse {
        var provenance: [String: Any] = [
            "identifier": "app:\(appName ?? "unknown")/\(sourceTitle ?? "")",
            "title": sourceTitle ?? NSNull(),
            "containerTitle": appName ?? NSNull(),
        ]
        if let selection, !selection.isEmpty {
            provenance["selection"] = selection
            provenance["selector"] = ["type": "TextQuote", "exact": selection]
        }
        var body: [String: Any] = [
            "spec": try spec(for: card),
            "provenance": provenance,
            "question": card.question,
            "answer": card.answer,
            "style": card.style.rawValue,
            "source_url": sourceUrl,
        ]
        if let sourceTitle, !sourceTitle.isEmpty { body["source_title"] = sourceTitle }
        if let selection, !selection.isEmpty { body["source_selection"] = selection }
        if let deckId { body["folder_id"] = deckId }

        let data = try await send(token: token, method: "POST", path: "/api/v1/cards", json: body)
        let saved = try JSONDecoder().decode(CardRow.self, from: data)

        var mochiCardId: String? = nil
        if AppState.shared.mochiEnabled {
            do {
                mochiCardId = try await sendCardToMochi(token: token, question: card.question, answer: card.answer, sourceUrl: sourceUrl)
            } catch {
                print("PluckkAPI: Mochi send failed (card still saved): \(error.localizedDescription)")
            }
        }
        return SendCardResponse(success: true, cardId: saved.id, mochiCardId: mochiCardId)
    }

    private func sendCardToMochi(token: String, question: String, answer: String, sourceUrl: String) async throws -> String? {
        struct MochiResponse: Decodable { let success: Bool; let cardId: String? }
        let data = try await send(token: token, method: "POST", path: "/api/send-to-mochi",
                                  json: ["question": question, "answer": answer, "sourceUrl": sourceUrl])
        return try JSONDecoder().decode(MochiResponse.self, from: data).cardId
    }

    // MARK: - Review (practice)
    // The server builds the session, schedules each rating and computes the interval
    // previews; the client only shows items and sends ratings back.

    /// A session using the user's Mix settings (deck shares, new-card caps, session size).
    func reviewSession(token: String) async throws -> [ReviewItem] {
        struct Response: Decodable { let items: [ReviewItem] }
        let data = try await send(token: token, method: "POST", path: "/api/v1/review/session", json: ["mode": "scheduled"])
        return try JSONDecoder().decode(Response.self, from: data).items
    }

    struct ReviewResult: Decodable {
        let event_id: String
        let previews: IntervalPreviews
    }

    func submitReview(token: String, item: ReviewItem, rating: ReviewRating, responseMs: Int) async throws -> ReviewResult {
        let data = try await send(token: token, method: "POST", path: "/api/v1/review", json: [
            "card_id": item.card_id, "component_id": item.component_id,
            "rating": rating.rawValue, "response_time_ms": responseMs,
        ])
        return try JSONDecoder().decode(ReviewResult.self, from: data)
    }

    /// Undo the rating with this event id; returns the item as it was before, when the server has it.
    func undoReview(token: String, eventId: String) async throws -> ReviewItem? {
        struct Response: Decodable { let item: ReviewItem? }
        let data = try await send(token: token, method: "POST", path: "/api/v1/review/undo", json: ["event_id": eventId])
        return try JSONDecoder().decode(Response.self, from: data).item
    }

    /// Edit a single-component card's question and answer. (Two-way and list cards need a
    /// full spec; the API rejects a plain question/answer edit for those.)
    func updateCard(token: String, cardId: String, question: String, answer: String) async throws {
        _ = try await send(token: token, method: "PATCH", path: "/api/v1/cards/\(cardId)",
                           json: ["question": question, "answer": answer])
    }

    /// Delete a card (all its components). Returns the event id, which /review/undo reverses.
    func deleteCard(token: String, cardId: String) async throws -> String? {
        struct Response: Decodable { let event_id: String? }
        let data = try await send(token: token, method: "DELETE", path: "/api/v1/cards/\(cardId)")
        return try JSONDecoder().decode(Response.self, from: data).event_id
    }

    // MARK: - Decks (folders) and Mochi decks

    private struct FolderRow: Decodable { let id: String; let name: String }

    func fetchDecks(token: String) async throws -> [Deck] {
        let data = try await send(token: token, method: "GET", path: "/api/v1/folders")
        return try JSONDecoder().decode([FolderRow].self, from: data).map { Deck(id: $0.id, name: $0.name) }
    }

    /// Lists the user's Mochi decks using the key stored server-side (never sends the key from the client).
    func fetchMochiDecks(token: String) async throws -> [MochiDeck] {
        struct Response: Decodable { let decks: [MochiDeck] }
        let data = try await send(token: token, method: "GET", path: "/api/import-from-mochi")
        return try JSONDecoder().decode(Response.self, from: data).decks
    }

    // MARK: - Transport

    private func send(token: String, method: String, path: String, json: [String: Any]) async throws -> Data {
        try await send(token: token, method: method, path: path, body: JSONSerialization.data(withJSONObject: json))
    }

    private func send(token: String, method: String, path: String, body: Data? = nil) async throws -> Data {
        let url = URL(string: "\(baseURL)\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = timeout

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }

        if http.statusCode == 401 {
            await AuthManager.shared.handleUnauthorized()
            throw APIError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            if let err = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                throw APIError.serverError(err.error ?? err.message ?? "Unknown error")
            }
            throw APIError.httpError(http.statusCode)
        }
        return data
    }

    struct ErrorResponse: Decodable {
        let error: String?
        let message: String?
    }
}

struct MochiDeck: Decodable {
    let id: String
    let name: String
}

/// One component of one card, as dealt by /api/v1/review/session (snake_case on the wire).
struct ReviewItem: Decodable, Identifiable {
    let card_id: String
    let component_id: String
    var question: String
    var answer: String
    let component_count: Int
    let image_url: String?
    let source_url: String?
    var is_new: Bool
    var previews: IntervalPreviews
    let folder: Folder?

    struct Folder: Decodable { let name: String? }

    var id: String { "\(card_id):\(component_id)" }
}

struct IntervalPreviews: Decodable {
    let again: String
    let hard: String
    let good: String
    let easy: String

    func label(for rating: ReviewRating) -> String {
        switch rating {
        case .again: return again
        case .hard: return hard
        case .good: return good
        case .easy: return easy
        }
    }
}

enum ReviewRating: String, CaseIterable {
    case again, hard, good, easy

    var title: String { rawValue.capitalized }
    /// Keys 1–4, as in the web app.
    var key: Character {
        switch self {
        case .again: return "1"
        case .hard: return "2"
        case .good: return "3"
        case .easy: return "4"
        }
    }
}

enum APIError: LocalizedError {
    case invalidResponse
    case httpError(Int)
    case serverError(String)
    case unauthorized

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid response from server"
        case .httpError(let code): return "HTTP error: \(code)"
        case .serverError(let message): return message
        case .unauthorized: return "Session expired. Please sign in again."
        }
    }
}
