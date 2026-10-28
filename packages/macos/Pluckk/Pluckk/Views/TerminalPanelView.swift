import SwiftUI
import AppKit
import SwiftTerm

/// A terminal inside Pluckk, opened from the rail: a login zsh in the Pluckk repo that starts
/// Claude Code (`claude personal`, Erik's shell function). One shared session lives for the life
/// of the app, so switching tabs or collapsing the panel doesn't end it; when it exits, "Start
/// again" opens a fresh one.
@MainActor
final class TerminalSession: NSObject, ObservableObject, LocalProcessTerminalViewDelegate {
    static let shared = TerminalSession()
    static let workingDirectory = NSString(string: "~/Documents/projects/active/pluckFull").expandingTildeInPath

    @Published private(set) var running = false
    /// Bumped on restart so the host swaps in the new view.
    @Published private(set) var generation = 0
    private(set) var view: LocalProcessTerminalView?

    /// The terminal view, started on first use.
    func terminalView() -> LocalProcessTerminalView {
        if let view { return view }
        let v = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        v.processDelegate = self
        v.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        v.nativeBackgroundColor = NSColor(calibratedWhite: 0.04, alpha: 1)
        v.nativeForegroundColor = NSColor(calibratedWhite: 0.9, alpha: 1)
        view = v
        launch()
        return v
    }

    func restart() {
        view?.terminate()
        view?.removeFromSuperview()
        view = nil
        generation += 1
    }

    /// End the session (Claude Code and its shell) without starting another.
    func end() {
        view?.terminate()
    }

    private func launch() {
        guard let view else { return }
        installScrollMonitor()
        // A clean environment: only the basics, and the login shell sets up the rest. Inheriting
        // Pluckk's own environment leaked another session's CLAUDE_* settings (e.g. when Pluckk
        // was launched from Claude Code), which made this one think it was a child session.
        let inherited = ProcessInfo.processInfo.environment
        var env: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
            "TERM_PROGRAM": "Pluckk",
        ]
        for key in ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "SSH_AUTH_SOCK"] {
            if let v = inherited[key] { env[key] = v }
        }
        let environment = env.map { "\($0.key)=\($0.value)" }
        // Interactive login zsh so PATH and the `claude` function load; land in the repo, start
        // Claude Code, and drop to a normal shell when it exits.
        let dir = Self.workingDirectory.replacingOccurrences(of: "'", with: "'\\''")
        let script = "cd '\(dir)' && claude personal; exec zsh -il"
        view.startProcess(executable: "/bin/zsh", args: ["-il", "-c", script], environment: environment,
                          execName: "-zsh")
        // Not inside SwiftUI's view update that created the view.
        DispatchQueue.main.async { self.running = true }
    }

    // MARK: Scrolling

    private var scrollMonitor: Any?
    private var scrollRemainder: CGFloat = 0

    /// Full-screen programs (Claude Code among them) draw on the terminal's alternate screen,
    /// which has no scrollback; SwiftTerm 1.11 only scrolls its own history, so the wheel did
    /// nothing. Over the terminal on the alternate screen, pass the wheel to the program as
    /// mouse-wheel events when it asked for the mouse, otherwise as ↑/↓ keys (what Terminal.app
    /// does). On the normal screen, SwiftTerm scrolls its history as before.
    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let view = self.view, event.window === view.window,
                  view.bounds.contains(view.convert(event.locationInWindow, from: nil)) else { return event }
            let terminal = view.getTerminal()
            guard terminal.isCurrentBufferAlternate else { return event }

            self.scrollRemainder += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 12 : event.scrollingDeltaY
            let lines = Int(self.scrollRemainder)
            guard lines != 0 else { return nil }
            self.scrollRemainder -= CGFloat(lines)

            if terminal.mouseMode != .off {
                let button = lines > 0 ? 4 : 5          // wheel up / down
                let flags = terminal.encodeButton(button: button, release: false, shift: false, meta: false, control: false)
                let point = view.convert(event.locationInWindow, from: nil)
                let col = max(0, Int(point.x / max(1, view.bounds.width) * CGFloat(terminal.cols)))
                let row = max(0, Int((view.bounds.height - point.y) / max(1, view.bounds.height) * CGFloat(terminal.rows)))
                for _ in 0..<abs(lines) { terminal.sendEvent(buttonFlags: flags, x: col, y: row) }
            } else {
                let up: [UInt8] = terminal.applicationCursor ? [0x1b, 0x4f, 0x41] : [0x1b, 0x5b, 0x41]
                let down: [UInt8] = terminal.applicationCursor ? [0x1b, 0x4f, 0x42] : [0x1b, 0x5b, 0x42]
                for _ in 0..<abs(lines) { view.send(lines > 0 ? up : down) }
            }
            return nil
        }
    }

    // MARK: LocalProcessTerminalViewDelegate

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor in self.running = false }
    }
}

/// The Terminal tab: the shared session's view, filling the panel, focused for typing.
struct TerminalPanelView: View {
    @ObservedObject private var session = TerminalSession.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal").font(.system(size: 10, weight: .semibold))
                Text("Claude Code · pluckFull").font(.system(size: 11, weight: .medium))
                Spacer()
                if session.running {
                    Button("Restart") { session.restart() }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundColor(.secondary)
                        .help("End this session and start a new one")
                    Button("End session") { session.end() }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundColor(Color(hex: "e5534b"))
                        .help("Quit Claude Code and the shell (other tabs: use the icons on the left)")
                }
            }
            .foregroundColor(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1) }

            ZStack(alignment: .bottom) {
            TerminalHost(generation: session.generation)
                .padding(.leading, 6)
                .padding(.top, 4)
            if !session.running {
                HStack(spacing: 10) {
                    Text("Session ended").font(.system(size: 12)).foregroundColor(.secondary)
                    Button("Start again") { session.restart() }
                        .buttonStyle(PillButtonStyle(prominent: true))
                }
                .padding(12)
                .background(Capsule().fill(Color.black.opacity(0.7)))
                .padding(.bottom, 16)
            }
            }
        }
    }
}

private struct TerminalHost: NSViewRepresentable {
    let generation: Int

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        attach(to: container)
    }

    /// The terminal view outlives this SwiftUI view (it's shared), so re-parent it into whichever
    /// container is on screen and give it keyboard focus.
    private func attach(to container: NSView) {
        let tv = TerminalSession.shared.terminalView()
        if tv.superview !== container {
            container.subviews.forEach { $0.removeFromSuperview() }
            tv.removeFromSuperview()
            tv.frame = container.bounds
            tv.autoresizingMask = [.width, .height]
            container.addSubview(tv)
        }
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
    }
}
