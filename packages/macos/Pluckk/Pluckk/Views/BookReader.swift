import SwiftUI
import SQLite3

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

    static func book(titled title: String) -> CorpusBook? {
        let key = title.lowercased()
        if let book = cache[key] { return book }
        guard let root = root else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2((root as NSString).appendingPathComponent("db/bookshelf.sqlite"), &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
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
        // Develops?" against "Children’s Thinking"), so compare them with quotes made plain, and
        // fall back to the main title before any colon.
        func plain(_ t: String) -> String {
            String(String.UnicodeScalarView(t.lowercased().unicodeScalars.map(CorpusBook.plain)))
                .trimmingCharacters(in: .whitespaces)
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

    var body: some View {
        let all = passage.paragraphs
        let centre = all.firstIndex { $0.marked != nil }
        let from = centre.map { max(0, $0 - before) } ?? 0
        let to = centre.map { min(all.count - 1, $0 + after) } ?? min(all.count - 1, after + before)
        VStack(alignment: .leading, spacing: 12) {
            header
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
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(isDark ? Color(hex: "151412") : Color(hex: "fbf8f2")))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "book").font(.system(size: 11)).foregroundColor(.secondary)
            Text(passage.book.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Text(passage.chapterTitle).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
            if let page = passage.page {
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
