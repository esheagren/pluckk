import SwiftUI

// Number cards in Practice: a best guess, then a range you're 95% sure holds the answer, laid on a
// ruler. On reveal the answer sweeps onto the same ruler, and the range sets the rating.

enum NumberText {
    static func isPercent(_ unit: String?) -> Bool {
        guard let unit else { return false }
        return ["%", "percent", "pct", "pp"].contains(unit.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// "1,200", "3.4e9", "45%", "2.5 million", "3bn", "7k".
    static func parse(_ text: String) -> Double? {
        let cleaned = text.lowercased().replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        let pattern = #"^([-+]?(?:\d+\.?\d*|\.\d+)(?:e[-+]?\d+)?)\s*(k|thousand|m|mn|million|b|bn|billion|t|tn|trillion)?\s*%?$"#
        guard let match = cleaned.range(of: pattern, options: .regularExpression) else { return nil }
        let body = String(cleaned[match])
        guard let number = body.range(of: #"^[-+]?(?:\d+\.?\d*|\.\d+)(?:e[-+]?\d+)?"#, options: .regularExpression),
              let value = Double(body[number]) else { return nil }
        let rest = body[number.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: " %"))
        let scale: Double
        switch rest {
        case "k", "thousand": scale = 1e3
        case "m", "mn", "million": scale = 1e6
        case "b", "bn", "billion": scale = 1e9
        case "t", "tn", "trillion": scale = 1e12
        default: scale = 1
        }
        return value * scale
    }

    static func format(_ value: Double) -> String {
        let magnitude = abs(value)
        for (size, word) in [(1e12, "trillion"), (1e9, "billion"), (1e6, "million")] where magnitude >= size {
            return "\(plain(value / size)) \(word)"
        }
        return plain(value)
    }

    private static func plain(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesSignificantDigits = true
        formatter.maximumSignificantDigits = abs(value) >= 1000 ? 6 : 4
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func withUnit(_ value: Double, _ unit: String?) -> String {
        guard let unit, !unit.isEmpty else { return format(value) }
        return isPercent(unit) ? "\(format(value))%" : "\(format(value)) \(unit)"
    }
}

/// The scale a range is drawn on. It comes from the range alone, never the hidden answer, and it
/// holds still through the reveal. Ranges spanning more than 5× use a log scale.
struct RulerScale {
    let low: Double
    let high: Double
    let logarithmic: Bool

    init(lower: Double, upper: Double, percent: Bool) {
        let lo = min(lower, upper), hi = max(lower, upper)
        if !percent, lo > 0, hi / lo > 5 {
            let pad = pow(hi / lo, 0.35)
            low = lo / pad; high = hi * pad; logarithmic = true
        } else {
            let width = hi > lo ? hi - lo : max(abs(lo) * 0.2, 1)
            var a = lo - width * 0.6, b = hi + width * 0.6
            if percent { a = max(0, a); b = min(100, b) }
            if lo >= 0 && a < 0 { a = 0 }
            low = a; high = b; logarithmic = false
        }
    }

    /// 0…1 across the ruler; outside that when off the scale.
    func position(_ value: Double) -> Double {
        if logarithmic {
            guard value > 0 else { return -1 }
            return (log(value) - log(low)) / (log(high) - log(low))
        }
        return high > low ? (value - low) / (high - low) : 0.5
    }
}

struct IntervalRuler: View {
    let lower: Double
    let upper: Double
    let unit: String?
    var answer: Double? = nil

    @State private var sweep = 0.0
    private static let answerColor = Color(hex: "8c9eff")

    var body: some View {
        let scale = RulerScale(lower: lower, upper: upper, percent: NumberText.isPercent(unit))
        GeometryReader { geo in
            let width = geo.size.width
            let x = { (v: Double) in CGFloat(min(max(scale.position(v), 0), 1)) * width }
            ZStack(alignment: .topLeading) {
                // The track and its ticks
                Rectangle().fill(Color.primary.opacity(0.15)).frame(width: width, height: 1).offset(y: 30)
                ForEach(0..<11) { i in
                    Rectangle().fill(Color.primary.opacity(i % 5 == 0 ? 0.3 : 0.15))
                        .frame(width: 1, height: i % 5 == 0 ? 9 : 5)
                        .offset(x: width * CGFloat(i) / 10, y: 31)
                }
                // Your range
                RoundedRectangle(cornerRadius: 3)
                    .fill(PluckkTheme.accent.opacity(0.35))
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(PluckkTheme.accent, lineWidth: 1.5))
                    .frame(width: max(x(upper) - x(lower), 3), height: 14)
                    .offset(x: x(lower), y: 23)
                Text(NumberText.format(lower)).font(.system(size: 11).monospacedDigit()).foregroundColor(.secondary)
                    .fixedSize().position(x: x(lower), y: 52)
                Text(NumberText.format(upper)).font(.system(size: 11).monospacedDigit()).foregroundColor(.secondary)
                    .fixedSize().position(x: x(upper), y: 52)

                if let answer {
                    let target = scale.position(answer)
                    let start = (scale.position(lower) + scale.position(upper)) / 2
                    let shown = CGFloat(min(max(start + (target - start) * sweep, 0), 1)) * width
                    let offScale = target < 0 || target > 1
                    Rectangle().fill(Self.answerColor).frame(width: 2, height: 26).offset(x: shown - 1, y: 17)
                    Text((offScale ? (target < 0 ? "← " : "") : "") + NumberText.withUnit(answer, unit) + (offScale && target > 1 ? " →" : ""))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundColor(Self.answerColor)
                        .fixedSize()
                        .position(x: min(max(shown, 40), width - 40), y: 7)
                        .opacity(sweep)
                }
            }
        }
        .frame(height: 60)
        .onAppear {
            guard answer != nil else { return }
            withAnimation(.easeOut(duration: 0.7)) { sweep = 1 }
        }
    }
}

/// Low and high: Return in low moves to high, Return in high locks it in.
struct IntervalEntry: View {
    let unit: String?
    let busy: Bool
    let onLock: (Double, Double) -> Void

    @State private var low = ""
    @State private var high = ""
    @State private var problem: String?
    @FocusState private var focus: Field?
    private enum Field { case low, high }

    private var percent: Bool { NumberText.isPercent(unit) }
    private var range: (Double, Double)? {
        guard let a = NumberText.parse(low), let b = NumberText.parse(high) else { return nil }
        return (min(a, b), max(a, b))
    }

    var body: some View {
        VStack(spacing: 14) {
            Text("Your 95% range").font(.system(size: 10, weight: .semibold)).tracking(0.7).foregroundColor(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                field("Low", $low, .low) { focus = .high }
                Text("to").foregroundColor(.secondary)
                field("High", $high, .high) { lock() }
                if let unit, !unit.isEmpty { Text(percent ? "%" : unit).foregroundColor(.secondary) }
            }
            .font(.system(size: 15))

            if let (lo, hi) = range {
                IntervalRuler(lower: lo, upper: hi, unit: unit).padding(.horizontal, 30)
            }

            Button(action: lock) {
                HStack(spacing: 6) {
                    if busy { ProgressView().controlSize(.small) }
                    Text("Lock in")
                    Text("↩").font(.system(size: 11, weight: .medium)).opacity(0.6)
                }
            }
            .buttonStyle(PillButtonStyle(prominent: true))
            .disabled(busy)
            if let problem {
                Text(problem).font(.system(size: 12)).foregroundColor(PluckkTheme.Dark.error)
            }
        }
        .onAppear { DispatchQueue.main.async { focus = .low } }
    }

    private func field(_ label: String, _ text: Binding<String>, _ which: Field, onSubmit: @escaping () -> Void) -> some View {
        TextField(label, text: text)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .font(.system(size: 17, weight: .semibold).monospacedDigit())
            .frame(width: 110)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(focus == which ? PluckkTheme.accent.opacity(0.7) : .clear, lineWidth: 1.5))
            .focused($focus, equals: which)
            .onSubmit(onSubmit)
            .onChange(of: text.wrappedValue) { _ in problem = nil }
    }

    private func lock() {
        guard let (lo, hi) = range else {
            problem = low.isEmpty || high.isEmpty ? "Enter a low and a high." : "That isn't a number."
            return
        }
        onLock(lo, hi)
    }
}

/// After locking in: your range and the answer on one ruler, and whether it caught it.
struct IntervalReveal: View {
    let outcome: PracticeSession.IntervalOutcome

    var body: some View {
        VStack(spacing: 8) {
            IntervalRuler(lower: outcome.lower, upper: outcome.upper, unit: outcome.unit, answer: outcome.answer)
                .padding(.horizontal, 30)
            Text(summary)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(outcome.contained ? PluckkTheme.Dark.success : Color(hex: "e5a14b"))
        }
    }

    private var summary: String {
        let range = "\(NumberText.format(outcome.lower))–\(NumberText.withUnit(outcome.upper, outcome.unit))"
        if outcome.contained { return "Caught it · your range \(range)" }
        let miss = outcome.answer < outcome.lower ? outcome.lower - outcome.answer : outcome.answer - outcome.upper
        let by = NumberText.isPercent(outcome.unit) ? "\(NumberText.format(miss)) points" : NumberText.withUnit(miss, outcome.unit)
        return "Missed by \(by) · your range \(range)"
    }
}

// MARK: - Typed blanks

/// Fill-in-the-blank cards (a question with ___) are answered by typing each blank, so a card
/// can't be passed on a vague "I think I know it". The card's answer gives the blanks in order,
/// separated by commas ("regression, classification"); "x / y" accepts either.
enum TypedBlanks {
    static let blank = try! NSRegularExpression(pattern: "_{2,}")

    static func count(in question: String) -> Int {
        blank.numberOfMatches(in: question, range: NSRange(question.startIndex..., in: question))
    }

    /// The expected text for each blank, or nil when the answer doesn't split into one per blank.
    static func expected(question: String, answer: String) -> [String]? {
        let n = count(in: question)
        guard n > 0 else { return nil }
        let first = (answer.components(separatedBy: "\n\n").first ?? answer).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !first.isEmpty else { return nil }
        if n == 1 { return [first] }
        let parts = first.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return parts.count == n ? parts : nil
    }

    enum Verdict { case right, close, wrong }

    struct Result: Equatable {
        let typed: String
        let expected: String
        let verdict: Verdict
    }

    /// Right if it matches once case, accents, punctuation, a leading article and anything in
    /// brackets are set aside; close if within a typo or two; otherwise wrong.
    static func judge(_ typed: String, _ expected: String) -> Verdict {
        let t = normal(typed)
        guard !t.isEmpty else { return .wrong }
        let options = expected.components(separatedBy: "/").map(normal).filter { !$0.isEmpty }
        if options.contains(t) { return .right }
        let near = options.contains { e in distance(t, e) <= max(1, e.count / 6) }
        return near ? .close : .wrong
    }

    static func score(_ results: [Result]) -> ModuleResponse {
        let right = results.filter { $0.verdict == .right }.count
        let close = results.filter { $0.verdict == .close }.count
        let score = right == results.count ? 0.8 : right + close == results.count ? 0.5 : 0.0
        let summary = results.count == 1
            ? (right == 1 ? "Right" : close == 1 ? "Close: check the spelling" : "Not quite")
            : "\(right) of \(results.count) right" + (close > 0 ? ", \(close) close" : "")
        return ModuleResponse(score: score, summary: summary)
    }

    static func normal(_ s: String) -> String {
        var t = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        t = t.replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
        t = String(t.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " })
        var words = t.split(separator: " ").map(String.init)
        if let first = words.first, ["the", "a", "an"].contains(first), words.count > 1 { words.removeFirst() }
        return words.joined(separator: " ")
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var prev = row[0]
            row[0] = i
            for j in 1...b.count {
                let cur = row[j]
                row[j] = a[i - 1] == b[j - 1] ? prev : min(prev, row[j], row[j - 1]) + 1
                prev = cur
            }
        }
        return row[b.count]
    }
}

/// A box per blank. Return moves to the next; on the last it checks.
struct TypedBlanksEntry: View {
    let count: Int
    let onCheck: ([String]) -> Void
    @State private var entries: [String] = []
    @FocusState private var focused: Int?

    var body: some View {
        VStack(spacing: 10) {
            ForEach(0..<count, id: \.self) { i in
                HStack(spacing: 8) {
                    if count > 1 {
                        Text("\(i + 1)").font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundColor(.secondary).frame(width: 14)
                    }
                    TextField(count > 1 ? "Blank \(i + 1)" : "Type the answer", text: binding(i))
                        .textFieldStyle(.plain)
                        .font(.system(size: 16))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                        .focused($focused, equals: i)
                        .onSubmit { if i + 1 < count { focused = i + 1 } else { check() } }
                }
                .frame(maxWidth: 420)
            }
            Button(action: check) {
                HStack(spacing: 6) { Text("Check"); Text("↩").font(.system(size: 11)).opacity(0.6) }
            }
            .buttonStyle(PillButtonStyle(prominent: true))
        }
        .onAppear {
            entries = Array(repeating: "", count: count)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = 0 }
        }
    }

    private func binding(_ i: Int) -> Binding<String> {
        Binding(get: { i < entries.count ? entries[i] : "" },
                set: { if i < entries.count { entries[i] = $0 } })
    }

    private func check() {
        PluckkPanel.shared?.hostWindow.makeFirstResponder(nil)
        onCheck(entries)
    }
}

/// After checking: what was typed against what was wanted, blank by blank.
struct TypedBlanksReveal: View {
    let results: [TypedBlanks.Result]

    var body: some View {
        VStack(spacing: 6) {
            ForEach(Array(results.enumerated()), id: \.offset) { i, r in
                HStack(spacing: 8) {
                    if results.count > 1 { Text("\(i + 1)").font(.system(size: 11).monospacedDigit()).foregroundColor(.secondary) }
                    Image(systemName: r.verdict == .right ? "checkmark.circle.fill" : r.verdict == .close ? "circle.lefthalf.filled" : "xmark.circle.fill")
                        .foregroundColor(r.verdict == .right ? PluckkTheme.Dark.success : r.verdict == .close ? Color(hex: "e5a14b") : Color(hex: "e5534b"))
                    Text(r.typed.isEmpty ? "(blank)" : r.typed)
                        .strikethrough(r.verdict == .wrong)
                        .foregroundColor(r.verdict == .right ? .primary : .secondary)
                    if r.verdict != .right {
                        Text("→ \(r.expected)").foregroundColor(.primary)
                    }
                }
                .font(.system(size: 14))
            }
        }
    }
}
