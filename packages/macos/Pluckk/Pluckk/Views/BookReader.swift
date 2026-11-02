import SwiftUI
import SQLite3

// "Read in context": a card made from a book in the bookshelf corpus opens that book's chapter,
// scrolled to the card's passage and highlighted. The text never leaves this Mac.

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
        let all = rows("select id, title, text_path from books", []).filter { $0.count == 3 }
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
        cache[key] = book
        return book
    }
}

extension BookLibrary {
    /// The reader opened on a card's passage: nil when the book isn't in the corpus; `found` is
    /// false when the passage couldn't be matched, and the chapter then opens at its top.
    static func passage(for source: BookSource) -> (passage: ReaderPassage, found: Bool)? {
        guard let book = book(titled: source.book) else { return nil }
        let hit = source.selection.flatMap { book.locate($0) }
        // The passage's place decides the chapter; failing that, the chapter title the card names.
        let chapter = hit.flatMap { book.chapterIndex(at: $0.start) }
            ?? source.chapter.flatMap { title in book.chapters.firstIndex { title.hasPrefix($0.title) || $0.title.hasPrefix(title) } }
            ?? 0
        return (ReaderPassage(book: book, chapter: chapter, highlight: hit), hit != nil)
    }
}

/// What the reader shows: a book, the chapter on screen, and the passage to highlight.
struct ReaderPassage: Identifiable {
    let id = UUID()
    let book: CorpusBook
    var chapter: Int
    let highlight: (start: Int, end: Int)?
}

struct ReaderView: View {
    @State var passage: ReaderPassage
    let onClose: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(CardTextScale.key) private var textScale = 1.0

    private var isDark: Bool { colorScheme == .dark }

    private struct Paragraph: Identifiable {
        let id: Int             // its start offset in the book
        let text: AttributedString
        let highlighted: Bool
    }

    private var chapter: BookChapter? {
        passage.book.chapters.indices.contains(passage.chapter) ? passage.book.chapters[passage.chapter] : nil
    }

    /// The chapter's lines as paragraphs, with the passage marked inside the ones it touches.
    private var paragraphs: [Paragraph] {
        guard let chapter else { return [] }
        let scalars = passage.book.scalars
        var out: [Paragraph] = []
        var lineStart = chapter.start
        for i in chapter.start...min(chapter.end, scalars.count) {
            guard i == min(chapter.end, scalars.count) || scalars[i] == "\n" else { continue }
            let line = passage.book.text(lineStart, i)
            if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                var text = AttributedString(line)
                var marked = false
                if let h = passage.highlight, h.start < i, h.end > lineStart {
                    let a = max(h.start, lineStart) - lineStart, b = min(h.end, i) - lineStart
                    let view = text.unicodeScalars
                    let lower = view.index(view.startIndex, offsetBy: a), upper = view.index(view.startIndex, offsetBy: b)
                    text[lower..<upper].backgroundColor = PluckkTheme.accent.opacity(isDark ? 0.38 : 0.32)
                    marked = true
                }
                out.append(Paragraph(id: lineStart, text: text, highlighted: marked))
            }
            lineStart = i + 1
        }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .background(Button("", action: onClose).keyboardShortcut(.cancelAction).opacity(0))
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    let items = paragraphs
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(items) { paragraph in
                            Text(paragraph.text)
                                .font(.system(size: 17 * CGFloat(textScale > 0 ? textScale : 1), design: .serif))
                                .lineSpacing(6)
                                .foregroundColor(isDark ? Color(hex: "e6e1d8") : Color(hex: "2b2925"))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .id(paragraph.id)
                        }
                        chapterNavigation.padding(.top, 20)
                    }
                    .frame(maxWidth: 680, alignment: .leading)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 28)
                    .frame(maxWidth: .infinity)
                }
                .onAppear { scroll(proxy, items: paragraphs) }
                .onChange(of: passage.chapter) { _ in scroll(proxy, items: paragraphs) }
            }
        }
        .background(isDark ? Color(hex: "121110") : Color(hex: "fbf8f2"))
    }

    /// Jumps to the passage once the text has laid out (a lazy stack only measures as it goes,
    /// so the jump is repeated briefly until it lands).
    private func scroll(_ proxy: ScrollViewProxy, items: [Paragraph]) {
        let marked = items.first(where: \.highlighted)
        guard let target = marked?.id ?? items.first?.id else { return }
        for delay in [0.05, 0.2, 0.45] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                proxy.scrollTo(target, anchor: marked == nil ? .top : UnitPoint(x: 0.5, y: 0.35))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: onClose) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                    Text("Back to card")
                }
            }
            .buttonStyle(QuietButtonStyle())
            .help("Back to the card (Esc)")
            VStack(alignment: .leading, spacing: 1) {
                Text(passage.book.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(chapter?.title ?? "").font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var chapterNavigation: some View {
        HStack {
            if passage.chapter > 0 {
                Button("← \(passage.book.chapters[passage.chapter - 1].title)") { passage.chapter -= 1 }
                    .buttonStyle(.plain).lineLimit(1)
            }
            Spacer()
            if passage.chapter + 1 < passage.book.chapters.count {
                Button("\(passage.book.chapters[passage.chapter + 1].title) →") { passage.chapter += 1 }
                    .buttonStyle(.plain).lineLimit(1)
            }
        }
        .font(.system(size: 12))
        .foregroundColor(.secondary)
    }
}
