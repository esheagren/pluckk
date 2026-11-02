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

/// Best guess, then low and high. Return in the guess offers a starting range; Return in high
/// locks it in. Narrower and Wider work around the middle of the range.
struct IntervalEntry: View {
    let unit: String?
    let busy: Bool
    let onLock: (Double, Double) -> Void

    @State private var guess = ""
    @State private var low = ""
    @State private var high = ""
    @State private var problem: String?
    @FocusState private var focus: Field?
    private enum Field { case guess, low, high }

    private var percent: Bool { NumberText.isPercent(unit) }
    private var range: (Double, Double)? {
        guard let a = NumberText.parse(low), let b = NumberText.parse(high) else { return nil }
        return (min(a, b), max(a, b))
    }

    var body: some View {
        VStack(spacing: 14) {
            Text("Your 95% range").font(.system(size: 10, weight: .semibold)).tracking(0.7).foregroundColor(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                field("Best guess", $guess, .guess, width: 110) {
                    if let g = NumberText.parse(guess), low.isEmpty || high.isEmpty { suggest(around: g) }
                    focus = .low
                }
                Text("·").foregroundColor(.secondary)
                field("Low", $low, .low, width: 96) { focus = .high }
                Text("to").foregroundColor(.secondary)
                field("High", $high, .high, width: 96) { lock() }
                if let unit, !unit.isEmpty { Text(percent ? "%" : unit).foregroundColor(.secondary) }
            }
            .font(.system(size: 15))

            if let (lo, hi) = range {
                IntervalRuler(lower: lo, upper: hi, unit: unit).padding(.horizontal, 30)
            }

            HStack(spacing: 8) {
                Button("Narrower") { resize(by: 0.75) }.buttonStyle(QuietButtonStyle()).disabled(range == nil)
                Button("Wider") { resize(by: 1.33) }.buttonStyle(QuietButtonStyle()).disabled(range == nil)
                Button(action: lock) {
                    HStack(spacing: 6) {
                        if busy { ProgressView().controlSize(.small) }
                        Text("Lock in")
                        Text("↩").font(.system(size: 11, weight: .medium)).opacity(0.6)
                    }
                }
                .buttonStyle(PillButtonStyle(prominent: true))
                .disabled(busy)
            }
            if let problem {
                Text(problem).font(.system(size: 12)).foregroundColor(PluckkTheme.Dark.error)
            }
        }
        .onAppear { DispatchQueue.main.async { focus = .guess } }
    }

    private func field(_ label: String, _ text: Binding<String>, _ which: Field, width: CGFloat,
                       onSubmit: @escaping () -> Void) -> some View {
        TextField(label, text: text)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .font(.system(size: 17, weight: .semibold).monospacedDigit())
            .frame(width: width)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(focus == which ? PluckkTheme.accent.opacity(0.7) : .clear, lineWidth: 1.5))
            .focused($focus, equals: which)
            .onSubmit(onSubmit)
            .onChange(of: text.wrappedValue) { _ in problem = nil }
    }

    /// A first range around the guess: ±10 points for a percentage, otherwise 0.7× to 1.4×.
    private func suggest(around g: Double) {
        if percent {
            set(max(0, g - 10), min(100, g + 10))
        } else if g == 0 {
            set(-1, 1)
        } else {
            let a = g * 0.7, b = g * 1.4
            set(min(a, b), max(a, b))
        }
    }

    private func resize(by factor: Double) {
        guard let (lo, hi) = range else { return }
        if !percent, lo > 0 {
            let middle = (lo * hi).squareRoot()
            let spread = pow(max(hi / lo, 1.02), factor)
            set(middle / spread.squareRoot(), middle * spread.squareRoot())
        } else {
            let middle = (lo + hi) / 2
            let half = max((hi - lo) / 2, max(abs(middle) * 0.02, 0.5)) * factor
            set(percent ? max(0, middle - half) : middle - half, percent ? min(100, middle + half) : middle + half)
        }
    }

    private func set(_ lo: Double, _ hi: Double) {
        low = NumberText.format(lo)
        high = NumberText.format(hi)
    }

    private func lock() {
        if range == nil, let g = NumberText.parse(guess) { suggest(around: g) }
        guard let (lo, hi) = range else {
            problem = "Enter a low and a high (or a best guess)."
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
        return "Missed by \(NumberText.withUnit(miss, outcome.unit)) · your range \(range)"
    }
}
