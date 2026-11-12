import SwiftUI
import SQLite3
import WebKit

// "Read in context": a card made from a book in the bookshelf corpus shows the passage it came
// from, highlighted among its neighbouring paragraphs, right under the card, with the printed page
// when the book's EPUB records one. The text never leaves this Mac.

struct BookChapter {
    let title: String
    let start: Int      // offsets in Unicode scalars, as the corpus stores them
    let end: Int
}

/// One book, loaded once, as Unicode scalars so the corpus's offsets index it directly.
final class CorpusBook {
    /// Its id in the corpus database, for searching its passages.
    var corpusId: Int?
    let title: String
    let chapters: [BookChapter]
    let scalars: [Unicode.Scalar]
    /// The EPUB the text was extracted from, for printed page numbers.
    var epubPath: String?
    private(set) lazy var normalised: String = String(String.UnicodeScalarView(scalars.map(CorpusBook.plain)))

    init(title: String, chapters: [BookChapter], text: String) {
        self.title = title
        self.chapters = chapters
        self.scalars = Array(text.unicodeScalars)
    }

    func text(_ start: Int, _ end: Int) -> String {
        String(String.UnicodeScalarView(scalars[max(0, start)..<min(end, scalars.count)]))
    }

    func chapterIndex(at offset: Int) -> Int? {
        chapters.firstIndex { offset >= $0.start && offset < $0.end }
    }

    /// Curly quotes, dashes and odd spaces made plain, one scalar for one, so offsets survive.
    static func plain(_ s: Unicode.Scalar) -> Unicode.Scalar {
        switch s {
        case "\u{2018}", "\u{2019}", "\u{201A}", "\u{201B}", "\u{2032}": return "'"
        case "\u{201C}", "\u{201D}", "\u{201E}", "\u{2033}": return "\""
        case "\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}", "\u{2212}": return "-"
        case "\u{00A0}", "\u{2009}", "\u{202F}": return " "
        default: return s
        }
    }

    /// Where a card's passage sits. Passages may skip words with "…"; the highlight runs from
    /// the first piece found to the end of the last one found after it.
    func locate(_ selection: String) -> (start: Int, end: Int)? {
        let pieces = selection.components(separatedBy: "…").flatMap { $0.components(separatedBy: "...") }
            .map { String(String.UnicodeScalarView($0.unicodeScalars.map(CorpusBook.plain))).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 8 }
        let haystack = normalised
        var start: Int?
        var end = 0
        var from = haystack.startIndex
        for piece in pieces {
            guard let found = haystack.range(of: piece, range: from..<haystack.endIndex)
                    ?? (start == nil ? haystack.range(of: piece, options: .caseInsensitive) : nil) else { continue }
            let s = haystack.unicodeScalars.distance(from: haystack.unicodeScalars.startIndex, to: found.lowerBound)
            if start == nil { start = s }
            end = s + piece.unicodeScalars.count
            from = found.upperBound
        }
        return start.map { ($0, max(end, $0)) }
    }
}

/// The bookshelf corpus: its database lists each book's title, text file and chapters.
@MainActor
enum BookLibrary {
    private static var cache: [String: CorpusBook] = [:]

    /// The corpus is whichever assistant folder holds db/bookshelf.sqlite, else the usual place.
    static var root: String? {
        let candidates = AssistantSettings.folders + [AssistantSettings.defaultFolders]
        return candidates.map { ($0 as NSString).expandingTildeInPath }
            .first { FileManager.default.fileExists(atPath: ($0 as NSString).appendingPathComponent("db/bookshelf.sqlite")) }
    }

    /// The corpus is in WAL mode, and a read-only connection can't read it while its -shm file is
    /// missing (nothing else has it open, or iCloud has swept the sidecar files away). Then read
    /// the main file as it stands, which holds everything once the log has been checkpointed.
    private static func openCorpus(_ path: String) -> OpaquePointer? {
        func attempt(_ name: String, _ flags: Int32) -> OpaquePointer? {
            var db: OpaquePointer?
            guard sqlite3_open_v2(name, &db, flags, nil) == SQLITE_OK,
                  sqlite3_exec(db, "SELECT 1 FROM books LIMIT 1", nil, nil, nil) == SQLITE_OK else {
                sqlite3_close(db)
                return nil
            }
            return db
        }
        let uri = URL(fileURLWithPath: path).absoluteString + "?immutable=1"
        return attempt(path, SQLITE_OPEN_READONLY) ?? attempt(uri, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI)
    }

    static func book(titled title: String) -> CorpusBook? {
        let key = title.lowercased()
        if let book = cache[key] { return book }
        guard let root = root else { return nil }
        guard let db = openCorpus((root as NSString).appendingPathComponent("db/bookshelf.sqlite")) else { return nil }
        defer { sqlite3_close(db) }

        func rows(_ sql: String, _ bind: [String]) -> [[String]] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (i, value) in bind.enumerated() { sqlite3_bind_text(statement, Int32(i + 1), value, -1, transient) }
            var out: [[String]] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                out.append((0..<sqlite3_column_count(statement)).map { column in
                    sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
                })
            }
            return out
        }

        // Titles are written differently on cards and in the corpus ("Children's Thinking: What
        // Develops?" against "Children’s Thinking", "The Lever of Riches" against "Lever of
        // Riches"), so compare them with quotes made plain and a leading article dropped, and fall
        // back to the main title before any colon.
        func plain(_ t: String) -> String {
            var s = String(String.UnicodeScalarView(t.lowercased().unicodeScalars.map(CorpusBook.plain)))
                .trimmingCharacters(in: .whitespaces)
            for article in ["the ", "a ", "an "] where s.hasPrefix(article) { s = String(s.dropFirst(article.count)); break }
            return s
        }
        func main(_ t: String) -> String {
            plain(t).components(separatedBy: ":").first!.trimmingCharacters(in: .whitespaces)
        }
        let all = rows("select id, title, text_path, coalesce(source_path, '') from books", []).filter { $0.count == 4 }
        let wanted = plain(title)
        let found = all.first { plain($0[1]) == wanted }
            ?? all.first { main($0[1]) == main(title) }
            ?? all.filter { plain($0[1]).hasPrefix(main(title)) || wanted.hasPrefix(main($0[1])) }
                .min { $0[1].count < $1[1].count }
        guard let found else { return nil }
        let chapters = rows("select title, start_char, end_char from chapters where book_id = ? order by ord", [found[0]])
            .map { BookChapter(title: $0[0], start: Int($0[1]) ?? 0, end: Int($0[2]) ?? 0) }
        var path = found[2]
        if !path.hasPrefix("/") { path = (root as NSString).appendingPathComponent(path) }
        if !FileManager.default.fileExists(atPath: path) {
            // Fall back to the text folder's naming: <slug>_<id>.txt
            let folder = (root as NSString).appendingPathComponent("text")
            if let name = (try? FileManager.default.contentsOfDirectory(atPath: folder))?.first(where: { $0.hasSuffix("_\(found[0]).txt") }) {
                path = (folder as NSString).appendingPathComponent(name)
            }
        }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let book = CorpusBook(title: found[1], chapters: chapters, text: text)
        book.corpusId = Int(found[0])
        if !found[3].isEmpty {
            book.epubPath = found[3].hasPrefix("/") ? found[3] : (root as NSString).appendingPathComponent(found[3])
        }
        cache[key] = book
        return book
    }
}

extension BookLibrary {
    /// A card's passage: nil when the book isn't in the corpus; `found` is false when the passage
    /// couldn't be matched, and the chapter then shows from its start.
    static func passage(for source: BookSource, cardId: String?) -> (passage: ReaderPassage, found: Bool)? {
        guard let book = book(titled: source.book) else { return nil }
        let hit = source.selection.flatMap { book.locate($0) }
        // The passage's place decides the chapter; failing that, the chapter title the card names.
        let chapter = hit.flatMap { book.chapterIndex(at: $0.start) }
            ?? source.chapter.flatMap { title in book.chapters.firstIndex { title.hasPrefix($0.title) || $0.title.hasPrefix(title) } }
            ?? 0
        return (ReaderPassage(book: book, chapter: chapter, highlight: hit, cardId: cardId, selection: source.selection), hit != nil)
    }
}

/// The source of one card: a book, its chapter, the passage, and the printed page once known.
struct ReaderPassage: Identifiable {
    let id = UUID()
    let book: CorpusBook
    let chapter: Int
    let highlight: (start: Int, end: Int)?
    let cardId: String?
    let selection: String?
    var page: String?
    /// The card's question and answer, to look for the book's discussion of it and a Wikipedia article.
    var query: String?

    var chapterTitle: String {
        book.chapters.indices.contains(chapter) ? book.chapters[chapter].title : ""
    }

    struct Paragraph: Identifiable {
        let id: Int             // its start offset in the book
        let range: Range<Int>
        let text: String
        var marked: Range<Int>? // the highlighted stretch, within this paragraph
    }

    /// The chapter's lines as paragraphs, noting where the passage falls in the ones it touches.
    var paragraphs: [Paragraph] {
        guard book.chapters.indices.contains(chapter) else { return [] }
        let c = book.chapters[chapter]
        let end = min(c.end, book.scalars.count)
        var out: [Paragraph] = []
        var lineStart = c.start
        for i in c.start...end {
            guard i == end || book.scalars[i] == "\n" else { continue }
            let line = book.text(lineStart, i)
            if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                var marked: Range<Int>?
                if let h = highlight, h.start < i, h.end > lineStart {
                    marked = (max(h.start, lineStart) - lineStart)..<(min(h.end, i) - lineStart)
                }
                out.append(Paragraph(id: lineStart, range: lineStart..<i, text: line, marked: marked))
            }
            lineStart = i + 1
        }
        return out
    }

    /// Plain text around the passage, with the passage set off in «», for the assistant.
    func excerpt(paragraphsAround: Int = 3, limit: Int = 8000) -> String {
        let all = paragraphs
        let centre = all.firstIndex { $0.marked != nil } ?? 0
        let window = all[max(0, centre - paragraphsAround)...min(all.count - 1, centre + paragraphsAround)]
        let text = window.map { p -> String in
            guard let m = p.marked else { return p.text }
            let scalars = Array(p.text.unicodeScalars)
            let piece = { (r: Range<Int>) in String(String.UnicodeScalarView(scalars[r])) }
            return piece(0..<m.lowerBound) + "«" + piece(m) + "»" + piece(m.upperBound..<scalars.count)
        }.joined(separator: "\n\n")
        return String(text.prefix(limit))
    }
}

/// Printed page numbers from a book's EPUB, which marks where each print page begins (with
/// doc-pagebreak elements or a page list). Kindle conversions usually have none.
enum EpubPages {
    private final class Map {
        let text: String
        let markers: [(offset: Int, label: String)]
        init(text: String, markers: [(offset: Int, label: String)]) { self.text = text; self.markers = markers }
    }
    private static var cache: [String: Map?] = [:]
    private static let lock = NSLock()

    /// The printed page a passage starts on, like "164", or nil when the EPUB has no page markers.
    static func label(epub: String, selection: String) -> String? {
        lock.lock()
        let cached = cache[epub]
        lock.unlock()
        let map: Map?
        if let cached { map = cached } else {
            map = build(epub)
            lock.lock(); cache[epub] = map; lock.unlock()
        }
        guard let map, !map.markers.isEmpty else { return nil }
        let pieces = selection.components(separatedBy: "…").flatMap { $0.components(separatedBy: "...") }
            .map(collapse).filter { $0.count >= 8 }.sorted { $0.count > $1.count }
        for piece in pieces {
            guard let found = map.text.range(of: piece) ?? map.text.range(of: piece, options: .caseInsensitive) else { continue }
            let offset = map.text.unicodeScalars.distance(from: map.text.unicodeScalars.startIndex, to: found.lowerBound)
            return map.markers.last { $0.offset <= offset }?.label
        }
        return nil
    }

    /// Quotes and dashes made plain and whitespace collapsed, as the page map's text is.
    static func collapse(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var space = false
        for scalar in s.unicodeScalars.map(CorpusBook.plain) {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !space { out.append(" ") }
                space = true
            } else {
                out.append(scalar)
                space = false
            }
        }
        return String(out).trimmingCharacters(in: .whitespaces)
    }

    private static func build(_ epub: String) -> Map? {
        guard FileManager.default.fileExists(atPath: epub) else { return nil }
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Pluckk/epub/\(abs(epub.hashValue))", isDirectory: true)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            unzip.arguments = ["-qq", "-o", epub, "-d", folder.path]
            unzip.standardOutput = FileHandle.nullDevice
            unzip.standardError = FileHandle.nullDevice
            guard (try? unzip.run()) != nil else { return nil }
            unzip.waitUntilExit()
        }
        func read(_ path: String) -> String? {
            guard let data = FileManager.default.contents(atPath: folder.appendingPathComponent(path).path) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
        func matches(_ pattern: String, in s: String) -> [[String]] {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
            let ns = s as NSString
            return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
                (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
            }
        }
        func attribute(_ name: String, _ tag: String) -> String? {
            matches("\\b\(name)\\s*=\\s*[\"']([^\"']*)[\"']", in: tag).first?[1]
        }

        guard let container = read("META-INF/container.xml"),
              let opfPath = matches("full-path\\s*=\\s*\"([^\"]+)\"", in: container).first?[1],
              let opf = read(opfPath) else { return nil }
        let base = (opfPath as NSString).deletingLastPathComponent
        var hrefs: [String: String] = [:]
        var navs: [String] = []
        for item in matches("<item\\b[^>]*>", in: opf).map({ $0[0] }) {
            guard let id = attribute("id", item), let href = attribute("href", item) else { continue }
            let path = base.isEmpty ? href : (base as NSString).appendingPathComponent(href)
            hrefs[id] = path.removingPercentEncoding ?? path
            if (attribute("properties", item) ?? "").contains("nav") || href.hasSuffix(".ncx") { navs.append(hrefs[id]!) }
        }
        let spine = matches("<itemref\\b[^>]*idref\\s*=\\s*\"([^\"]+)\"", in: opf).compactMap { hrefs[$0[1]] }

        // Page lists name the element where each page starts: id → printed page.
        var listed: [String: String] = [:]
        for nav in navs {
            guard let text = read(nav) else { continue }
            if let start = text.range(of: "page-list") {
                let section = String(text[start.lowerBound...])
                let end = section.range(of: "</nav>")?.lowerBound ?? section.endIndex
                for link in matches("<a\\b[^>]*href\\s*=\\s*\"[^\"#]*#([^\"]+)\"[^>]*>([^<]*)</a>", in: String(section[..<end])) {
                    listed[link[1]] = link[2].trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            for target in matches("<pageTarget\\b[^>]*>.*?<text>([^<]*)</text>.*?<content\\s+src\\s*=\\s*\"[^\"#]*#([^\"]+)\"", in: text) {
                listed[target[2]] = target[1].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        var out = String.UnicodeScalarView()
        var count = 0
        var space = true
        var markers: [(offset: Int, label: String)] = []
        func append(_ text: String) {
            for scalar in text.unicodeScalars.map(CorpusBook.plain) {
                if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    if !space { out.append(" "); count += 1 }
                    space = true
                } else {
                    out.append(scalar); count += 1
                    space = false
                }
            }
        }
        func entityDecoded(_ s: String) -> String {
            guard s.contains("&") else { return s }
            var t = s
            for (k, v) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'"), ("&rsquo;", "\u{2019}"), ("&lsquo;", "\u{2018}"), ("&ldquo;", "\u{201C}"), ("&rdquo;", "\u{201D}"), ("&mdash;", "\u{2014}"), ("&ndash;", "\u{2013}"), ("&hellip;", "\u{2026}")] {
                t = t.replacingOccurrences(of: k, with: v)
            }
            for m in matches("&#(x?)([0-9a-f]+);", in: t) {
                if let n = UInt32(m[2], radix: m[1].isEmpty ? 10 : 16), let u = Unicode.Scalar(n) {
                    t = t.replacingOccurrences(of: m[0], with: String(Character(u)))
                }
            }
            return t.replacingOccurrences(of: "&amp;", with: "&")
        }
        for path in spine {
            guard let html = read(path) else { continue }
            let body = html.range(of: "<body", options: .caseInsensitive).map { String(html[$0.lowerBound...]) } ?? html
            var cursor = body.startIndex
            while let open = body[cursor...].firstIndex(of: "<") {
                append(entityDecoded(String(body[cursor..<open])))
                guard let close = body[open...].firstIndex(of: ">") else { break }
                let tag = String(body[open...close])
                let isBreak = tag.contains("doc-pagebreak") || tag.contains("epub:type=\"pagebreak\"")
                if isBreak, let raw = attribute("aria-label", tag) ?? attribute("title", tag) ?? attribute("id", tag).flatMap({ listed[$0] }) {
                    let label = raw.replacingOccurrences(of: "page", with: "", options: .caseInsensitive)
                        .trimmingCharacters(in: CharacterSet(charactersIn: " .\u{00A0}"))
                    if !label.isEmpty { markers.append((count, label)) }
                } else if let id = attribute("id", tag), let label = listed[id] {
                    markers.append((count, label))
                }
                if tag.range(of: "^</?(p|div|br|h[1-6]|li|tr|td|blockquote|section|figure)\\b", options: [.regularExpression, .caseInsensitive]) != nil {
                    append(" ")
                }
                cursor = body.index(after: close)
            }
        }
        return Map(text: String(out), markers: markers)
    }
}

/// The card's source, under the card: the passage highlighted with a few paragraphs either side,
/// more on request, and the printed page when known.
struct SourceExcerpt: View {
    let passage: ReaderPassage
    let onClose: () -> Void
    @State private var before = 2
    @State private var after = 2
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(CardTextScale.key) private var textScale = 1.0

    private var isDark: Bool { colorScheme == .dark }

    /// Wikipedia has its own note under the card (WikiNote), for every card, not only book ones.
    enum Tab: String, CaseIterable { case passage = "Passage", book = "In the book" }
    @State private var tab = Tab.passage

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            switch tab {
            case .passage: passageView
            case .book: BookEvidenceView(passage: passage, isDark: isDark, textScale: textScale)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(isDark ? Color(hex: "151412") : Color(hex: "fbf8f2")))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }

    /// The card's own passage, in its chapter.
    @ViewBuilder private var passageView: some View {
        let all = passage.paragraphs
        let centre = all.firstIndex { $0.marked != nil }
        let from = centre.map { max(0, $0 - before) } ?? 0
        let to = centre.map { min(all.count - 1, $0 + after) } ?? min(all.count - 1, after + before)
        VStack(alignment: .leading, spacing: 12) {
            if from > 0 { moreButton("More above", "chevron.up") { before += 4 } }
            if !all.isEmpty {
                ForEach(all[from...to]) { paragraph in
                    Text(attributed(paragraph))
                        .font(.system(size: 15 * CGFloat(textScale > 0 ? textScale : 1), design: .serif))
                        .lineSpacing(5)
                        .foregroundColor(isDark ? Color(hex: "e6e1d8") : Color(hex: "2b2925"))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if to < all.count - 1 { moreButton("More below", "chevron.down") { after += 4 } }
        }
    }

    /// Everything on one line: the book and chapter, and the tabs.
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "book").font(.system(size: 11)).foregroundColor(.secondary)
            Text(passage.book.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                .layoutPriority(1)
                .help(passage.book.title + (passage.chapterTitle.isEmpty ? "" : " · " + passage.chapterTitle))
            Text(passage.chapterTitle).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            if let page = passage.page, tab == .passage {
                Text("p. \(page)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundColor(PluckkTheme.accent)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(PluckkTheme.accent.opacity(0.14)))
                    .help("The printed page, from the book's EPUB")
            }
            Spacer(minLength: 8)
            Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("Hide the source")
        }
    }

    private func moreButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9, weight: .semibold))
                Text(title)
            }
            .font(.system(size: 11))
            .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
    }

    private func attributed(_ p: ReaderPassage.Paragraph) -> AttributedString {
        var text = AttributedString(p.text)
        guard let m = p.marked else { return text }
        let view = text.unicodeScalars
        let lower = view.index(view.startIndex, offsetBy: m.lowerBound), upper = view.index(view.startIndex, offsetBy: m.upperBound)
        text[lower..<upper].backgroundColor = PluckkTheme.accent.opacity(isDark ? 0.38 : 0.32)
        return text
    }
}

extension ReaderPassage {
    /// Looks up the printed page in the background and hands back the passage with it.
    func withPage() async -> String? {
        guard let epub = book.epubPath, let selection else { return nil }
        return await Task.detached(priority: .userInitiated) { EpubPages.label(epub: epub, selection: selection) }.value
    }
}

// MARK: - The book's own discussion of a card

/// Where the rest of the book takes up what the card asks: a card made from an introduction or a
/// summary points here to the chapters that argue it. Found with the corpus's own hybrid search
/// (BM25 plus its embedding model), run in its Python, skipping the card's own passage.
enum BookEvidence {
    struct Hit: Decodable, Identifiable {
        let start: Int
        let end: Int
        let chapter: String?
        var id: Int { start }
    }

    private static var cache: [String: [Hit]] = [:]

    static func find(book: CorpusBook, query: String, exclude: (start: Int, end: Int)?, key: String) async throws -> [Hit] {
        if let hits = cache[key] { return hits }
        guard let id = book.corpusId, let root = await BookLibrary.root else { throw RelatedCards.Failure("The bookshelf corpus isn't set up.") }
        let python = (root as NSString).appendingPathComponent(".venv/bin/python")
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Pluckk", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let script = support.appendingPathComponent("book-evidence.py")
        try Self.script.write(to: script, atomically: true, encoding: .utf8)
        let request: [String: Any] = ["root": root, "book_id": id, "query": String(query.prefix(1500)), "k": 4,
                                      "exclude": exclude.map { [$0.start, $0.end] } ?? []]
        let input = try JSONSerialization.data(withJSONObject: request)
        let output: Data = try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = [script.path]
            process.currentDirectoryURL = URL(fileURLWithPath: root)
            process.environment = ["HF_HUB_OFFLINE": "1", "TOKENIZERS_PARALLELISM": "false", "HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"]
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
              let hits = try? JSONDecoder().decode([Hit].self, from: Data(last.utf8)) else {
            throw RelatedCards.Failure("The book search didn't return anything.")
        }
        cache[key] = hits
        return hits
    }

    private static let script = #"""
import sys, json
req = json.load(sys.stdin)
sys.path.insert(0, req["root"] + "/scripts")
import search as S
conn = S.open_db(req["root"] + "/db/bookshelf.sqlite")
ex = req.get("exclude") or []
pad = 6000
rows = S.search_chunks(conn, req["query"], k=req.get("k", 4) * 10, book_ids=[req["book_id"]])
out = []
for r in rows:
    s, e = r.get("start_char"), r.get("end_char")
    if s is None: continue
    if ex and s < ex[1] + pad and e > ex[0] - pad: continue          # the card's own passage
    if any(s < o["end"] + 1500 and e > o["start"] - 1500 for o in out): continue   # one per stretch
    out.append({"start": s, "end": e, "chapter": r.get("chapter_title")})
    if len(out) >= req.get("k", 4): break
print(json.dumps(out))
"""#
}

struct BookEvidenceView: View {
    let passage: ReaderPassage
    let isDark: Bool
    let textScale: Double
    @State private var hits: [BookEvidence.Hit]?
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let hits {
                if hits.isEmpty {
                    Text("Nothing else in the book stood out for this card.").font(.system(size: 12)).foregroundColor(.secondary)
                }
                ForEach(hits) { hit in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(label(hit)).font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                        Text(passage.book.text(hit.start, hit.end).trimmingCharacters(in: .whitespacesAndNewlines))
                            .font(.system(size: 14 * CGFloat(textScale > 0 ? textScale : 1), design: .serif))
                            .lineSpacing(4)
                            .foregroundColor(isDark ? Color(hex: "e6e1d8") : Color(hex: "2b2925"))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
                }
                Text("Found by searching the rest of the book for what the card asks, skipping the card's own passage.")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            } else if let problem {
                Text(problem).font(.system(size: 12)).foregroundColor(.secondary)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking through the book…").font(.system(size: 12)).foregroundColor(.secondary)
                }
            }
        }
        .task(id: passage.id) {
            do {
                hits = try await BookEvidence.find(book: passage.book, query: passage.query ?? passage.selection ?? "",
                                                   exclude: passage.highlight, key: "\(passage.book.title)|\(passage.cardId ?? passage.selection ?? "")")
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    /// Chapter, or how far through the book when it has no chapters.
    private func label(_ hit: BookEvidence.Hit) -> String {
        if let chapter = hit.chapter, !chapter.isEmpty { return chapter }
        let total = max(1, passage.book.scalars.count)
        return "\(Int(Double(hit.start) / Double(total) * 100))% through the book"
    }
}

// MARK: - Wikipedia under a card

/// A card's Wikipedia article. The card carries it: chosen by the model that wrote the card, or
/// (the first time it's asked for) by the Wikipedia agent on Pluckk's server, which searches
/// Wikipedia and names the article that covers the card's subject, or none. A choice made here,
/// from a search or "look again", is saved on the card too.
@MainActor
final class WikiPick: ObservableObject {
    /// The article's opening, as Wikipedia's summary gives it.
    struct Summary: Equatable {
        let extract: String
        let description: String?
        let thumbnail: URL?
    }

    @Published var title: String?
    /// Articles from the search box, to choose from.
    @Published var candidates: [String] = []
    @Published var problem: String?
    @Published var summary: Summary?
    /// The agent is looking.
    @Published var finding = false
    private var cardId: String?
    private var started: String?

    /// Open on a card: the article it has; otherwise ask the agent, once.
    func start(cardId: String, stored: String?) {
        guard started != cardId else { return }
        started = cardId
        self.cardId = cardId
        candidates = []
        problem = nil
        summary = nil
        title = nil
        if let stored, !stored.isEmpty { show(stored) } else { ask(force: false) }
    }

    /// Have the agent look (again, with `force`), and show what it finds.
    func ask(force: Bool) {
        guard let cardId else { return }
        finding = true
        problem = nil
        Task {
            defer { if started == cardId { finding = false } }
            guard let token = AuthManager.shared.accessToken else { problem = "Sign in to look for an article."; return }
            do {
                let found = try await PluckkAPI.shared.cardWikipedia(token: token, cardId: cardId, force: force)
                guard started == cardId else { return }
                PracticeSession.shared.applyExternalWikipedia(cardId: cardId, title: found)
                if let found { show(found) } else {
                    title = nil
                    summary = nil
                    problem = "No Wikipedia article covers this card well. Search for one above if you know it."
                }
            } catch {
                if started == cardId { problem = "Couldn't look for an article just now. Search above, or try again." }
            }
        }
    }

    /// The person's choice: shown, and saved on the card.
    func choose(_ t: String) {
        show(t)
        save(t)
    }

    /// "None of these": the card has no article.
    func chooseNone() {
        title = nil
        summary = nil
        problem = "No article for this card. Search above to give it one."
        save(nil)
    }

    private func save(_ t: String?) {
        guard let cardId, let token = AuthManager.shared.accessToken else { return }
        PracticeSession.shared.applyExternalWikipedia(cardId: cardId, title: t)
        Task { try? await PluckkAPI.shared.setCardWikipedia(token: token, cardId: cardId, title: t) }
    }

    private func show(_ t: String) {
        guard t != title || summary == nil else { return }
        title = t
        summary = nil
        problem = nil
        Task { await loadSummary(t) }
    }

    /// The search box: what was typed, its results to choose from, the first one shown and saved.
    func search(_ text: String) async {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, var c = URLComponents(string: "https://en.wikipedia.org/w/api.php") else { return }
        c.queryItems = [.init(name: "action", value: "query"), .init(name: "list", value: "search"), .init(name: "srsearch", value: q),
                        .init(name: "srlimit", value: "8"), .init(name: "format", value: "json")]
        let asked = started
        guard let url = c.url, let (data, response) = try? await URLSession.shared.data(for: Self.request(url)),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            if asked == started, title == nil { problem = "Couldn't reach Wikipedia. Try again in a moment." }
            return
        }
        guard asked == started else { return }
        let found = ((json["query"] as? [String: Any])?["search"] as? [[String: Any]] ?? []).compactMap { $0["title"] as? String }
        candidates = found
        if let first = found.first { choose(first) } else if title == nil { problem = "No Wikipedia article matched that search." }
    }

    /// The article's opening paragraph, its one-line description and a picture, for the note.
    private func loadSummary(_ t: String) async {
        let name = t.replacingOccurrences(of: " ", with: "_")
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        guard let path = name.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(path)") else { return }
        guard let (data, _) = try? await URLSession.shared.data(for: Self.request(url)), title == t,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let extract = (json["extract"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let thumb = ((json["thumbnail"] as? [String: Any])?["source"] as? String).flatMap(URL.init(string:))
        summary = Summary(extract: extract.isEmpty ? "Wikipedia has no summary for this article. Open the whole article below." : extract,
                          description: json["description"] as? String, thumbnail: thumb)
    }

    nonisolated private static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Pluckk/1.0 (spaced-repetition app)", forHTTPHeaderField: "User-Agent")
        return request
    }

    static func url(_ title: String, mobile: Bool) -> URL? {
        let path = title.replacingOccurrences(of: " ", with: "_").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? title
        return URL(string: "https://\(mobile ? "en.m" : "en").wikipedia.org/wiki/\(path)")
    }
}

/// Wikipedia under a card, a step at a time: the article's opening paragraph first, the whole
/// article on request. The article can be swapped (a search, or asking Claude to look again), and
/// the choice is saved on the card.
struct WikiNote: View {
    @ObservedObject var pick: WikiPick
    let onClose: () -> Void
    @State private var whole = false
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(CardTextScale.key) private var textScale = 1.0

    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("W").font(.system(size: 14, weight: .semibold, design: .serif)).foregroundColor(.secondary)
                    .help("Wikipedia")
                WikiControls(pick: pick)
                Spacer(minLength: 8)
                Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .help("Hide Wikipedia (W or Esc)")
            }
            if pick.finding {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Claude is finding the article for this card…").font(.system(size: 12)).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            } else if let problem = pick.problem {
                Text(problem).font(.system(size: 12)).foregroundColor(.secondary)
            } else if whole {
                WikiContent(pick: pick)
            } else if let summary = pick.summary {
                opening(summary)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 60)
            }
            if pick.problem == nil, pick.title != nil {
                Button(action: { withAnimation(.easeOut(duration: 0.18)) { whole.toggle() } }) {
                    HStack(spacing: 4) {
                        Image(systemName: whole ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .semibold))
                        Text(whole ? "Back to the opening paragraph" : "Read the whole article")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(isDark ? Color(hex: "151412") : Color(hex: "fbf8f2")))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }

    /// The article's one-line description, its opening paragraph, and its picture beside them.
    private func opening(_ summary: WikiPick.Summary) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                if let description = summary.description, !description.isEmpty {
                    Text(description.prefix(1).uppercased() + description.dropFirst())
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }
                Text(summary.extract)
                    .font(.system(size: 15 * CGFloat(textScale > 0 ? textScale : 1), design: .serif))
                    .lineSpacing(5)
                    .foregroundColor(isDark ? Color(hex: "e6e1d8") : Color(hex: "2b2925"))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let thumbnail = summary.thumbnail {
                AsyncImage(url: thumbnail) { $0.resizable().aspectRatio(contentMode: .fit) } placeholder: { Color.clear }
                    .frame(maxWidth: 150, maxHeight: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }
}

/// The article picker, search and open-in-browser, on the note's one header line.
struct WikiControls: View {
    @ObservedObject var pick: WikiPick
    @State private var searchText = ""

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(pick.candidates.filter { $0 != pick.title }, id: \.self) { t in Button(t) { pick.choose(t) } }
                if !pick.candidates.isEmpty { Divider() }
                Button("Ask Claude to look again") { pick.ask(force: true) }
                Button("No article fits this card") { pick.chooseNone() }
            } label: {
                Text(pick.title ?? (pick.finding ? "Finding the article…" : "No article"))
                    .font(.system(size: 12, weight: .semibold)).lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Choose another article; your choice is saved on the card")
            TextField("Search Wikipedia", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .controlSize(.small)
                .frame(minWidth: 90, maxWidth: 170)
                .onSubmit { Task { await pick.search(searchText) } }
            if let title = pick.title, let url = WikiPick.url(title, mobile: false) {
                Button(action: { NSWorkspace.shared.open(url) }) { Image(systemName: "arrow.up.right.square").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundColor(.secondary).help("Open in the browser")
            }
        }
    }
}

/// The article itself, tall and stripped of Wikipedia's own header and footer so it reads like a page.
struct WikiContent: View {
    @ObservedObject var pick: WikiPick

    var body: some View {
        if let problem = pick.problem {
            Text(problem).font(.system(size: 12)).foregroundColor(.secondary)
        } else if let title = pick.title, let url = WikiPick.url(title, mobile: true) {
            WikiWebView(url: url)
                .frame(height: 760)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .id(title)
        } else {
            ProgressView().controlSize(.small)
        }
    }
}

private struct WikiWebView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ModuleContainer {
        let config = WKWebViewConfiguration()
        let css = """
        .header-container, .minerva-header, .banner-container, .page-actions-menu, .minerva-footer, footer,
        .mw-footer, #mw-mf-page-left, .last-modified-bar, .post-content.footer-content, .mw-portlet-associated-pages,
        .minerva__tab-container, .page-heading .tagline { display: none !important; }
        body { font-size: 17px !important; }
        .content, #content { max-width: 760px; margin: 0 auto; }
        """
        let js = "var s=document.createElement('style');s.textContent=`\(css)`;document.documentElement.appendChild(s);"
        config.userContentController.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.load(URLRequest(url: url))
        return ModuleContainer(web)
    }

    func updateNSView(_ view: ModuleContainer, context: Context) {}

    /// Wikipedia stays in the panel; links elsewhere open in the browser.
    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let host = action.request.url?.host ?? ""
            if host.hasSuffix("wikipedia.org") || host.hasSuffix("wikimedia.org") || action.navigationType == .other { decisionHandler(.allow); return }
            if let url = action.request.url { NSWorkspace.shared.open(url) }
            decisionHandler(.cancel)
        }
    }
}
