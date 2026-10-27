import SwiftUI
import AppKit

/// A short, timed practice sprint (4 minutes by default; Settings changes it). Starting one
/// switches to Practice; when it runs out, Practice shows how many cards you did and offers
/// another. Several short sprints rather than one long session.
@MainActor
final class SessionTimer: ObservableObject {
    static let shared = SessionTimer()
    static let minutesKey = "practiceMinutes"
    static let defaultMinutes = 4

    @Published private(set) var endsAt: Date?
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

    func start() {
        now = Date()
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
    }

    private func tick() {
        now = Date()
        guard remaining <= 0 else { return }
        stop()
        NSSound(named: "Glass")?.play()
        PracticeSession.shared.timeUp()
    }
}

/// The timer at the top of the panel: "▶ 4:00" to start, a countdown with a thin progress
/// ring while running (click to stop).
struct SessionTimerView: View {
    @ObservedObject private var timer = SessionTimer.shared
    @State private var hovering = false

    var body: some View {
        Button(action: { timer.isRunning ? timer.stop() : timer.start() }) {
            HStack(spacing: 6) {
                if timer.isRunning {
                    ZStack {
                        Circle().stroke(Color.primary.opacity(0.15), lineWidth: 2)
                        Circle()
                            .trim(from: 0, to: timer.progress)
                            .stroke(PluckkTheme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 1), value: timer.progress)
                        if hovering {
                            Image(systemName: "stop.fill").font(.system(size: 5))
                        }
                    }
                    .frame(width: 12, height: 12)
                    Text(clock(timer.remaining))
                } else {
                    Image(systemName: "play.fill").font(.system(size: 8))
                    Text(clock(Double(timer.minutes * 60)))
                }
            }
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            .foregroundColor(timer.isRunning ? PluckkTheme.accent : Color.primary.opacity(hovering ? 0.85 : 0.55))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.primary.opacity(hovering || timer.isRunning ? 0.08 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(timer.isRunning ? "Stop the timer" : "Start a \(timer.minutes)-minute practice session")
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
