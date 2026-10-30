import SwiftUI
import AppKit

/// A short, timed practice sprint (4 minutes by default; the clock or Settings changes it).
/// Revealing a card starts one; starting one switches to Practice; when it runs out, Practice shows how many cards you did and offers
/// another. Several short sprints rather than one long session.
@MainActor
final class SessionTimer: ObservableObject {
    static let shared = SessionTimer()
    static let minutesKey = "practiceMinutes"
    static let defaultMinutes = 4

    @Published private(set) var endsAt: Date?
    private var startedAt: Date?
    @Published private(set) var now = Date()
    private var ticker: Timer?

    var minutes: Int {
        let m = UserDefaults.standard.integer(forKey: Self.minutesKey)
        return m > 0 ? m : Self.defaultMinutes
    }
    var isRunning: Bool { endsAt != nil }
    var remaining: TimeInterval { max(0, (endsAt ?? now).timeIntervalSince(now)) }
    var progress: Double {
        guard isRunning else { return 0 }
        return 1 - remaining / Double(minutes * 60)
    }

    private init() {}

    /// Set the sprint length; a running sprint takes the new length from when it started.
    func setMinutes(_ value: Int) {
        UserDefaults.standard.set(value, forKey: Self.minutesKey)
        if let startedAt, isRunning { endsAt = startedAt.addingTimeInterval(Double(value * 60)) }
        objectWillChange.send()
    }

    func start() {
        now = Date()
        startedAt = now
        endsAt = now.addingTimeInterval(Double(minutes * 60))
        AppState.shared.currentView = .practice
        PracticeSession.shared.beginSprint()
        ticker?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    func stop() {
        ticker?.invalidate()
        ticker = nil
        endsAt = nil
        startedAt = nil
    }

    /// Stopped by hand: don't let the next reveal start another sprint straight away.
    func cancel() {
        stop()
        PracticeSession.shared.suppressAutoStart()
    }

    private func tick() {
        now = Date()
        guard remaining <= 0 else { return }
        stop()
        NSSound(named: "Glass")?.play()
        PracticeSession.shared.timeUp()
    }
}

/// The top bar's centre: one strip holding the clock and today's counts. While a sprint runs the
/// strip itself fills from the left, so the time is shown once. Clicking it opens a row of minute
/// choices inline (a popover misbehaves on this non-activating panel). Sprints start themselves
/// when a card is revealed, so the click changes the time; the row also has Start or Stop.
struct SessionTimerView: View {
    @ObservedObject private var timer = SessionTimer.shared
    @AppStorage(SessionTimer.minutesKey) private var storedMinutes = SessionTimer.defaultMinutes
    @State private var hovering = false
    @State private var picking = false

    private static let presets = [2, 4, 8, 15, 30]
    private var minutes: Int { storedMinutes > 0 ? storedMinutes : SessionTimer.defaultMinutes }
    private var choices: [Int] { Array(Set(Self.presets + [minutes])).sorted() }

    var body: some View {
        HStack(spacing: 8) {
            strip
            if picking {
                minutePicker
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: picking)
    }

    private var strip: some View {
        let running = timer.isRunning
        return Button(action: { picking.toggle() }) {
            HStack(spacing: 9) {
                Text(clock(running ? timer.remaining : Double(minutes * 60)))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundColor(running ? PluckkTheme.accent : Color.primary.opacity(hovering || picking ? 0.85 : 0.6))
                if !picking { TodayCountsLabel() }
            }
            .padding(.horizontal, 14)
            .frame(height: 26)
            .background(fill)
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(running ? "Change the time, or stop" : "Change the minutes")
    }

    private var fill: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Color.primary.opacity(hovering || picking ? 0.09 : 0.055)
                Rectangle()
                    .fill(PluckkTheme.accent.opacity(0.24))
                    .frame(width: geo.size.width * timer.progress)
                    .animation(.linear(duration: 1), value: timer.progress)
            }
        }
    }

    private var minutePicker: some View {
        HStack(spacing: 2) {
            ForEach(choices, id: \.self) { value in
                Button("\(value)") {
                    timer.setMinutes(value)
                    picking = false
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: value == minutes ? .semibold : .regular).monospacedDigit())
                .foregroundColor(value == minutes ? PluckkTheme.accent : Color.primary.opacity(0.6))
                .frame(minWidth: 24, minHeight: 22)
                .background(Capsule().fill(value == minutes ? PluckkTheme.accent.opacity(0.14) : .clear))
                .contentShape(Rectangle())
            }
            Text("min").font(.system(size: 11)).foregroundColor(.secondary).padding(.trailing, 6)
            Button(timer.isRunning ? "Stop" : "Start") {
                timer.isRunning ? timer.cancel() : timer.start()
                picking = false
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(timer.isRunning ? Color(hex: "e5534b") : PluckkTheme.accent)
        }
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// "76 review · 68 new": what's left today across the mix. New is what today's limits still
/// allow, not every unseen card.
struct TodayCountsLabel: View {
    @ObservedObject private var session = PracticeSession.shared

    var body: some View {
        if let counts = session.todayCounts {
            Group {
                if counts.review == 0 && counts.learn == 0 {
                    Text("Done for today")
                } else {
                    Text("\(counts.review) review · \(counts.learn) new")
                }
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundColor(.secondary)
            .fixedSize()
            .help("Cards due for review today · new cards today's limits still allow")
        }
    }
}
