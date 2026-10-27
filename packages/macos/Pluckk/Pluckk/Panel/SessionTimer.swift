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

/// The timer at the top of the panel: "▶ 4:00" to start; once a sprint starts it grows (larger
/// type and ring, a springy pop) and counts down, so the minutes are the focus. Click to stop.
struct SessionTimerView: View {
    @ObservedObject private var timer = SessionTimer.shared
    @State private var hovering = false
    @State private var pop = false

    var body: some View {
        let running = timer.isRunning
        Button(action: { running ? timer.cancel() : timer.start() }) {
            HStack(spacing: running ? 8 : 6) {
                if running {
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
                    .frame(width: 15, height: 15)
                    Text(clock(timer.remaining))
                } else {
                    Image(systemName: "play.fill").font(.system(size: 8))
                    Text(clock(Double(timer.minutes * 60)))
                }
            }
            .font(.system(size: running ? 16 : 12, weight: .semibold).monospacedDigit())
            .foregroundColor(running ? PluckkTheme.accent : Color.primary.opacity(hovering ? 0.85 : 0.55))
            .padding(.horizontal, running ? 14 : 10)
            .padding(.vertical, running ? 5 : 4)
            .background(Capsule().fill(running ? PluckkTheme.accent.opacity(0.14) : Color.primary.opacity(hovering ? 0.08 : 0)))
            .contentShape(Capsule())
            .scaleEffect(pop ? 1.12 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.35, dampingFraction: 0.6), value: running)
        .onChange(of: running) { isOn in
            guard isOn else { return }
            // A brief pop on start, settling to the larger running size.
            withAnimation(.spring(response: 0.25, dampingFraction: 0.5)) { pop = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { pop = false }
            }
        }
        .help(running ? "Stop the timer" : "Start a \(timer.minutes)-minute practice session")
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
