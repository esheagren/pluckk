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

    private func launch() {
        guard let view else { return }
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
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
