import SwiftUI

/// GitHub-style grid of practice days: one column per week (newest on the right), one cell
/// per day, shaded by how many reviews that day. Shows as many weeks as fit the width (up to a
/// year). Counts come from the server, so web and Mac reviews both show.
struct ActivityGrid: View {
    @State private var counts: [String: Int] = [:]
    @State private var loaded = false

    private let cell: CGFloat = 10
    private let gap: CGFloat = 3

    private static let dayKey: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                let weeks = max(4, min(53, Int((geo.size.width + gap) / (cell + gap))))
                grid(weeks: weeks)
            }
            .frame(height: 7 * cell + 6 * gap)

            HStack(spacing: 4) {
                Text(summary).font(.caption).foregroundColor(.secondary)
                Spacer()
                Text("Less").font(.caption2).foregroundColor(.secondary)
                ForEach(0..<5) { level in
                    RoundedRectangle(cornerRadius: 2).fill(color(level: level)).frame(width: cell, height: cell)
                }
                Text("More").font(.caption2).foregroundColor(.secondary)
            }
        }
        .task { await load() }
    }

    private func grid(weeks: Int) -> some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        // The last column ends with today; columns start on the calendar's first weekday.
        let weekdayOffset = (cal.component(.weekday, from: today) - cal.firstWeekday + 7) % 7
        let start = cal.date(byAdding: .day, value: -(weeks - 1) * 7 - weekdayOffset, to: today)!
        return HStack(alignment: .top, spacing: gap) {
            ForEach(0..<weeks, id: \.self) { w in
                VStack(spacing: gap) {
                    ForEach(0..<7, id: \.self) { d in
                        let day = cal.date(byAdding: .day, value: w * 7 + d, to: start)!
                        if day > today {
                            Color.clear.frame(width: cell, height: cell)
                        } else {
                            let n = counts[Self.dayKey.string(from: day)] ?? 0
                            RoundedRectangle(cornerRadius: 2)
                                .fill(color(level: level(n)))
                                .frame(width: cell, height: cell)
                                .help("\(n) review\(n == 1 ? "" : "s") · \(day.formatted(date: .abbreviated, time: .omitted))")
                        }
                    }
                }
            }
        }
    }

    private func level(_ n: Int) -> Int {
        switch n {
        case 0: return 0
        case 1..<10: return 1
        case 10..<30: return 2
        case 30..<60: return 3
        default: return 4
        }
    }

    private func color(level: Int) -> Color {
        level == 0 ? Color.primary.opacity(0.08) : PluckkTheme.accent.opacity([0, 0.3, 0.55, 0.8, 1][level])
    }

    /// Practice days in the last 30 and the current streak (today counts if you've practised).
    private var summary: String {
        guard loaded else { return "Loading…" }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let practiced: (Date) -> Bool = { (counts[Self.dayKey.string(from: $0)] ?? 0) > 0 }
        let last30 = (0..<30).filter { practiced(cal.date(byAdding: .day, value: -$0, to: today)!) }.count
        var streak = 0
        var day = practiced(today) ? today : cal.date(byAdding: .day, value: -1, to: today)!
        while practiced(day) {
            streak += 1
            day = cal.date(byAdding: .day, value: -1, to: day)!
        }
        return "\(last30) of the last 30 days · \(streak)-day streak"
    }

    private func load() async {
        guard let token = AuthManager.shared.accessToken else { return }
        counts = (try? await PluckkAPI.shared.reviewActivity(token: token)) ?? [:]
        loaded = true
    }
}
