import Foundation

/// New cards go into the nearest topic deck. The decks were made by clustering card embeddings
/// (deck-centroids.json in Application Support); a card with no deck is embedded on this Mac with
/// the same model, using the bookshelf corpus's Python, and moved to the deck it's closest to. Runs
/// at launch and every half hour, and only starts Python when there's an unfiled card.
@MainActor
final class DeckFiler {
    static let shared = DeckFiler()
    private var timer: Timer?
    private var running = false

    nonisolated private static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Pluckk", isDirectory: true)
    }

    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.run() }
        timer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.run() }
        }
    }

    func run() {
        let centroids = Self.support.appendingPathComponent("deck-centroids.json")
        guard !running, let token = AuthManager.shared.accessToken, let root = BookLibrary.root,
              FileManager.default.fileExists(atPath: centroids.path) else { return }
        let python = (root as NSString).appendingPathComponent(".venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: python) else { return }
        running = true
        Task {
            defer { running = false }
            guard let data = try? await PluckkAPI.shared.raw(token: token, method: "GET",
                                                             path: "/api/v1/cards?folder_id=unfiled&limit=1", json: nil),
                  let waiting = try? JSONSerialization.jsonObject(with: data) as? [Any], !waiting.isEmpty else { return }
            let script = Self.support.appendingPathComponent("deck-filer.py")
            try? Self.script.write(to: script, atomically: true, encoding: .utf8)
            let output = await Task.detached(priority: .utility) { () -> String in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: python)
                process.arguments = [script.path]
                process.environment = ["PLUCKK_API": Config.backendURL, "PLUCKK_TOKEN": token,
                                       "PLUCKK_SUPPORT": Self.support.path, "HF_HUB_OFFLINE": "1",
                                       "HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                guard (try? process.run()) != nil else { return "couldn't start python" }
                let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
                return text
            }.value
            let log = Self.support.appendingPathComponent("deck-filer.log")
            let line = "\(Date().ISO8601Format()) \(output.split(separator: "\n").last.map(String.init) ?? "")\n"
            if let handle = try? FileHandle(forWritingTo: log) {
                handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
            } else {
                try? line.write(to: log, atomically: true, encoding: .utf8)
            }
            PracticeSession.shared.refreshTodayCounts()
        }
    }

    nonisolated private static let script = #"""
import os, sys, json, sqlite3, hashlib, re, urllib.request
import numpy as np

API, TOKEN, SUPPORT = os.environ["PLUCKK_API"], os.environ["PLUCKK_TOKEN"], os.environ["PLUCKK_SUPPORT"]

def call(method, path, body=None):
    req = urllib.request.Request(API + "/api/v1" + path, method=method,
                                 data=None if body is None else json.dumps(body).encode(),
                                 headers={"Authorization": "Bearer " + TOKEN, "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)

def text(c):
    # A leading "Book title: " would group cards by source, not topic.
    q = re.sub(r"^[^:?]{3,60}: ", "", c["question"].strip())
    return f"{q}\n{c['answer'].strip().split(chr(10))[0]}"

cards = call("GET", "/cards?folder_id=unfiled&limit=500")
if not cards:
    print(json.dumps({"filed": 0})); sys.exit()
plan = json.load(open(os.path.join(SUPPORT, "deck-centroids.json")))
live = {f["id"] for f in call("GET", "/folders")}
decks = [d for d in plan["decks"] if d["folder_id"] in live]
if not decks:
    print(json.dumps({"filed": 0, "note": "no decks"})); sys.exit()

db = sqlite3.connect(os.path.join(SUPPORT, "card-embeddings.sqlite"))
db.execute("create table if not exists embeddings (card_id text primary key, text_hash text, vector blob)")
have = {r[0]: (r[1], r[2]) for r in db.execute("select card_id, text_hash, vector from embeddings")}
digest = {c["id"]: hashlib.sha1(text(c).encode()).hexdigest() for c in cards}
todo = [c for c in cards if have.get(c["id"], (None,))[0] != digest[c["id"]]]
if todo:
    from sentence_transformers import SentenceTransformer
    model = SentenceTransformer(plan["model"], trust_remote_code=True)
    vectors = model.encode(["clustering: " + text(c) for c in todo], normalize_embeddings=True, show_progress_bar=False)
    db.executemany("insert or replace into embeddings values (?,?,?)",
                   [(c["id"], digest[c["id"]], v.astype(np.float32).tobytes()) for c, v in zip(todo, vectors)])
    db.commit()
    have = {r[0]: (r[1], r[2]) for r in db.execute("select card_id, text_hash, vector from embeddings")}

centroids = np.array([d["centroid"] for d in decks], dtype=np.float32)
filed = {}
for c in cards:
    v = np.frombuffer(have[c["id"]][1], dtype=np.float32)
    deck = decks[int(np.argmax(centroids @ v))]
    call("PATCH", f"/cards/{c['id']}", {"folder_id": deck["folder_id"]})
    filed[deck["name"]] = filed.get(deck["name"], 0) + 1
print(json.dumps({"filed": sum(filed.values()), "into": filed}))
"""#
}


/// Cards close in meaning to a text or to another card, from the same local embeddings the topic
/// decks use. Cards without an embedding yet (or edited since) are embedded first. The pinned
/// decks (Spanish, Art) aren't embedded, so they aren't searched.
enum RelatedCards {
    static let pinnedDecks: Set<String> = ["Spanish Top 5000", "Art · Artists"]

    struct Match: Decodable { let id: String; let score: Double }

    static func search(query: String?, cardId: String?, among cards: [[String: Any]], limit: Int) async throws -> [Match] {
        guard let root = await BookLibrary.root else { throw Failure("The bookshelf corpus, whose Python runs the embedding model, isn't set up.") }
        let python = (root as NSString).appendingPathComponent(".venv/bin/python")
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Pluckk", isDirectory: true)
        let script = support.appendingPathComponent("related-cards.py")
        try Self.script.write(to: script, atomically: true, encoding: .utf8)
        var request: [String: Any] = ["limit": limit, "cards": cards.map {
            ["id": $0["id"] ?? "", "question": $0["question"] ?? "", "answer": $0["answer"] ?? ""]
        }]
        if let query { request["query"] = query }
        if let cardId { request["card_id"] = cardId }
        let input = try JSONSerialization.data(withJSONObject: request)
        let output: Data = try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = [script.path]
            process.environment = ["PLUCKK_SUPPORT": support.path, "HF_HUB_OFFLINE": "1", "HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"]
            let stdin = Pipe(), stdout = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            try process.run()
            stdin.fileHandleForWriting.write(input)
            try stdin.fileHandleForWriting.close()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return data
        }.value
        guard let last = String(decoding: output, as: UTF8.self).split(separator: "\n").last,
              let matches = try? JSONDecoder().decode([Match].self, from: Data(last.utf8)) else {
            throw Failure("The embedding search didn't return anything.")
        }
        return matches
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private static let script = #"""
import os, sys, json, sqlite3, hashlib, re
import numpy as np

req = json.load(sys.stdin)
SUPPORT = os.environ["PLUCKK_SUPPORT"]

def text(c):
    # Same text as the topic decks were made from: no "Book title: " prefix, the answer's first line.
    q = re.sub(r"^[^:?]{3,60}: ", "", c["question"].strip())
    return f"{q}\n{c['answer'].strip().split(chr(10))[0]}"

db = sqlite3.connect(os.path.join(SUPPORT, "card-embeddings.sqlite"))
db.execute("create table if not exists embeddings (card_id text primary key, text_hash text, vector blob)")
have = {r[0]: (r[1], r[2]) for r in db.execute("select card_id, text_hash, vector from embeddings")}
cards = req["cards"]
digest = {c["id"]: hashlib.sha1(text(c).encode()).hexdigest() for c in cards}
model = None
def embed(texts):
    global model
    if model is None:
        from sentence_transformers import SentenceTransformer
        model = SentenceTransformer("nomic-ai/nomic-embed-text-v1.5", trust_remote_code=True)
    return model.encode(["clustering: " + t for t in texts], normalize_embeddings=True, show_progress_bar=False)

todo = [c for c in cards if have.get(c["id"], (None,))[0] != digest[c["id"]]][:300]
if todo:
    vectors = embed([text(c) for c in todo])
    db.executemany("insert or replace into embeddings values (?,?,?)",
                   [(c["id"], digest[c["id"]], v.astype(np.float32).tobytes()) for c, v in zip(todo, vectors)])
    db.commit()
    have = {r[0]: (r[1], r[2]) for r in db.execute("select card_id, text_hash, vector from embeddings")}

ids = [c["id"] for c in cards if c["id"] in have]
if not ids:
    print("[]"); sys.exit()
matrix = np.stack([np.frombuffer(have[i][1], dtype=np.float32) for i in ids])
if req.get("card_id") in have:
    q = np.frombuffer(have[req["card_id"]][1], dtype=np.float32)
else:
    q = embed([req.get("query", "")])[0]
scores = matrix @ q
order = [i for i in np.argsort(-scores) if ids[i] != req.get("card_id")][: int(req.get("limit", 10))]
print(json.dumps([{"id": ids[i], "score": round(float(scores[i]), 3)} for i in order]))
"""#
}
