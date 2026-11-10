import Foundation
import JavaScriptCore

/// Practice without the network. While online, Pluckk keeps a snapshot of the account on this Mac
/// (GET sync/snapshot: cards, review states, today's deck limits). When the API can't be reached,
/// sessions are dealt and rated from it by the same engine the server runs (pluckk-core.js in
/// JavaScriptCore), and each rating waits in an outbox until it can be sent, with the time it
/// happened, so the server replays it at that moment.
@MainActor
final class OfflineStore: ObservableObject {
    static let shared = OfflineStore()

    /// The API couldn't be reached on the last try; Practice is using the snapshot.
    @Published private(set) var offline = false
    /// Ratings made offline, not yet sent.
    @Published private(set) var pending = 0
    @Published private(set) var snapshotTakenAt: Date?

    struct PendingRating: Codable {
        let card_id: String
        let component_id: String
        let rating: String
        let at: String
        let response_time_ms: Int?
        let reveal_ms: Int?
    }

    private var context: JSContext?
    private var core: JSValue?
    private var outbox: [PendingRating] = []
    private var refreshing = false
    private var flushing = false

    /// Per Mac, not in iCloud: each device keeps its own copy and outbox.
    private var folder: URL {
        let url = PluckkFiles.localFolder.appendingPathComponent("offline", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private var snapshotFile: URL { folder.appendingPathComponent("snapshot.json") }
    private var outboxFile: URL { folder.appendingPathComponent("outbox.json") }

    private init() {
        if let data = try? Data(contentsOf: outboxFile), let saved = try? JSONDecoder().decode([PendingRating].self, from: data) {
            outbox = saved
            pending = saved.count
        }
        snapshotTakenAt = (try? FileManager.default.attributesOfItem(atPath: snapshotFile.path))?[.modificationDate] as? Date
    }

    // MARK: Network state

    static func isNetworkError(_ error: Error) -> Bool {
        guard let e = error as? URLError else { return false }
        return [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost,
                .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed, .secureConnectionFailed].contains(e.code)
    }

    func wentOffline() { if !offline { offline = true } }

    /// Back online: send what's waiting, then refresh the copy if it's stale.
    func cameOnline() {
        if offline { offline = false }
        Task {
            await flush()
            await refreshIfStale()
        }
    }

    // MARK: The engine

    /// Loads the snapshot into the engine (once), replaying ratings still in the outbox.
    private func engine() -> JSValue? {
        if let core { return core }
        guard let script = Bundle.main.url(forResource: "pluckk-core", withExtension: "js"),
              let source = try? String(contentsOf: script, encoding: .utf8),
              let snapshot = try? String(contentsOf: snapshotFile, encoding: .utf8),
              let ctx = JSContext() else { return nil }
        ctx.exceptionHandler = { _, e in NSLog("Pluckk offline engine: \(e?.toString() ?? "?")") }
        ctx.evaluateScript(source)
        guard let api = ctx.objectForKeyedSubscript("PluckkCore"), !api.isUndefined else { return nil }
        api.invokeMethod("load", withArguments: [snapshot])
        for r in outbox { api.invokeMethod("rate", withArguments: [r.card_id, r.component_id, r.rating, r.at]) }
        context = ctx
        core = api
        return api
    }

    private static func now() -> String { ISO8601DateFormatter().string(from: Date()) }

    var hasSnapshot: Bool { FileManager.default.fileExists(atPath: snapshotFile.path) }

    /// A session from the snapshot: scheduled mix, one deck (focus), or new cards past today's limits (ahead).
    func deal(focus: String??, ahead: Int?) -> [ReviewItem] {
        guard let api = engine() else { return [] }
        var opts: [String: Any] = ["mode": "scheduled"]
        if let focus { opts = ["mode": "focus", "folderId": focus.map { $0 as Any } ?? NSNull()] }
        if let ahead { opts["mode"] = "ahead"; opts["size"] = ahead }
        guard let json = try? JSONSerialization.data(withJSONObject: opts),
              let out = api.invokeMethod("deal", withArguments: [String(decoding: json, as: UTF8.self), Self.now()])?.toString(),
              let items = try? JSONDecoder().decode([ReviewItem].self, from: Data(out.utf8)) else { return [] }
        return items
    }

    /// Rate in the snapshot and queue the rating for the server. Returns the card's new previews.
    func rate(_ item: ReviewItem, rating: ReviewRating, responseMs: Int?, revealMs: Int?) -> IntervalPreviews? {
        guard let api = engine() else { return nil }
        let at = Self.now()
        guard let out = api.invokeMethod("rate", withArguments: [item.card_id, item.component_id, rating.rawValue, at])?.toString() else { return nil }
        struct Rated: Decodable { let previews: IntervalPreviews }
        let rated = try? JSONDecoder().decode(Rated.self, from: Data(out.utf8))
        outbox.append(PendingRating(card_id: item.card_id, component_id: item.component_id, rating: rating.rawValue, at: at,
                                    response_time_ms: responseMs, reveal_ms: revealMs))
        saveOutbox()
        return rated?.previews
    }

    /// Stands in for a server event id on a rating made offline, so Undo knows to take it back out of the outbox.
    static let offlineEventId = "offline"

    /// Undo the latest unsent rating of this card; the engine reloads and replays what's left.
    func undoLast(cardId: String) {
        guard let i = outbox.lastIndex(where: { $0.card_id == cardId }) else { return }
        outbox.remove(at: i)
        saveOutbox()
        core = nil
        context = nil
    }

    func today() -> TodayCounts? {
        guard let api = engine(), let out = api.invokeMethod("today", withArguments: [Self.now()])?.toString() else { return nil }
        return try? JSONDecoder().decode(TodayCounts.self, from: Data(out.utf8))
    }

    private func saveOutbox() {
        pending = outbox.count
        if let data = try? JSONEncoder().encode(outbox) { try? data.write(to: outboxFile, options: .atomic) }
    }

    // MARK: Sync

    /// Send queued ratings, oldest first, each with its own time. Stops at the first network
    /// failure; a rating the server refuses (a deleted card, say) is dropped.
    func flush() async {
        guard !flushing, !outbox.isEmpty, let token = AuthManager.shared.accessToken else { return }
        flushing = true
        defer { flushing = false }
        while let next = outbox.first {
            var body: [String: Any] = ["card_id": next.card_id, "component_id": next.component_id, "rating": next.rating, "at": next.at]
            if let ms = next.response_time_ms { body["response_time_ms"] = ms }
            if let ms = next.reveal_ms { body["reveal_ms"] = ms }
            do {
                _ = try await PluckkAPI.shared.raw(token: token, method: "POST", path: "/api/v1/review", json: body)
            } catch {
                if Self.isNetworkError(error) { wentOffline(); return }
                NSLog("Pluckk: dropped an offline rating the server refused: \(error.localizedDescription)")
            }
            if offline { offline = false }
            outbox.removeFirst()
            saveOutbox()
        }
        // The server now has everything; the next refresh starts clean.
        await refresh()
    }

    func refreshIfStale(maxAge: TimeInterval = 30 * 60) async {
        if let at = snapshotTakenAt, Date().timeIntervalSince(at) < maxAge { return }
        await refresh()
    }

    /// Download the snapshot in pages and keep it. Skipped while ratings are waiting to be sent,
    /// so the copy never forgets them.
    func refresh() async {
        guard !refreshing, outbox.isEmpty, let token = AuthManager.shared.accessToken else { return }
        refreshing = true
        defer { refreshing = false }
        let pageSize = 1500
        do {
            let first = try JSONSerialization.jsonObject(with: try await PluckkAPI.shared.raw(
                token: token, method: "GET", path: "/api/v1/sync/snapshot?offset=0&limit=\(pageSize)", json: nil)) as? [String: Any]
            guard var snapshot = first?["snapshot"] as? [String: Any], var cards = first?["cards"] as? [Any] else { return }
            let total = first?["total_cards"] as? Int ?? cards.count
            var offset = cards.count
            while offset < total {
                let page = try JSONSerialization.jsonObject(with: try await PluckkAPI.shared.raw(
                    token: token, method: "GET", path: "/api/v1/sync/snapshot?offset=\(offset)&limit=\(pageSize)", json: nil)) as? [String: Any]
                let more = page?["cards"] as? [Any] ?? []
                if more.isEmpty { break }
                cards += more
                offset += more.count
            }
            snapshot["cards"] = cards
            let data = try JSONSerialization.data(withJSONObject: snapshot)
            try data.write(to: snapshotFile, options: .atomic)
            snapshotTakenAt = Date()
            core = nil          // reload on next use
            context = nil
        } catch {
            if Self.isNetworkError(error) { wentOffline() }
        }
    }
}
