import AppKit
import SwiftUI

struct SidebarView: View {
    let isExpanded: Bool
    var panelWidth: CGFloat = 600
    var isPinned: Bool = false
    @ObservedObject private var appState = AppState.shared
    @Environment(\.colorScheme) var colorScheme

    private var backgroundColor: Color {
        colorScheme == .dark ? PluckkTheme.Dark.table : PluckkTheme.Light.table
    }

    var body: some View {
        Group {
            if isExpanded {
                expandedContent
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                // Pill-shaped handle when collapsed
                AmbientStripView(state: stripState)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
                    .opacity(0.75)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: PluckkTheme.Animation.slow), value: isExpanded)
    }

    private var stripState: AmbientStripView.State {
        if appState.isGenerating {
            return .generating
        } else if !appState.generatedCards.isEmpty {
            return .ready
        }
        return .idle
    }

    @ViewBuilder
    private var expandedContent: some View {
        ZStack {
            // A plain, still surface so the cards are the focus
            backgroundColor.ignoresSafeArea()

            VStack(spacing: 0) {
                GripBar(isPinned: isPinned)
                    .zIndex(1)  // hover labels draw over the content below

                // Main content based on current view
                Group {
                    switch appState.currentView {
                    case .generate:
                        if appState.isAuthenticated {
                            CardGenerationView()
                        } else {
                            LoginView()
                        }
                    case .practice:
                        if appState.isAuthenticated {
                            PracticeView()
                        } else {
                            LoginView()
                        }
                    case .settings:
                        SettingsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // One resize grip, bottom-right corner
            VStack { Spacer(); HStack { Spacer(); CornerResizeHandle() } }
        }
    }
}

// MARK: - Grip bar (move handle + close and pin buttons)

/// The strip across the top of the card. Dragging anywhere on it moves the window;
/// the red dot on the left closes (collapses) the panel; the pin on the right keeps the
/// card on the current desktop instead of following the user. Between them sits the
/// icon toolbar: Create (card generation), Practice (native review), and Settings.
struct GripBar: View {
    let isPinned: Bool
    @ObservedObject private var appState = AppState.shared
    @State private var closeHovering = false
    @State private var pinHovering = false

    var body: some View {
        ZStack {
            WindowDragArea()

            HStack(spacing: 4) {
                ToolbarTab(icon: "sparkles", label: "Create", isActive: appState.currentView == .generate) {
                    appState.currentView = .generate
                }
                ToolbarTab(icon: "rectangle.stack", label: "Practice", isActive: appState.currentView == .practice) {
                    appState.currentView = .practice
                }
                ToolbarTab(icon: "gearshape", label: "Settings", isActive: appState.currentView == .settings) {
                    appState.currentView = .settings
                }
            }

            HStack {
                Button(action: { PluckkPanel.shared?.collapse() }) {
                    ZStack {
                        Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.34))
                        Image(systemName: "xmark")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundColor(.black.opacity(0.6))
                            .opacity(closeHovering ? 1 : 0)
                    }
                    .frame(width: 12, height: 12)
                }
                .buttonStyle(.plain)
                .onHover { closeHovering = $0 }
                .help("Close")
                Spacer()
                Button(action: { PluckkPanel.shared?.togglePinned() }) {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(45))
                        .foregroundColor(isPinned ? Color(red: 1.0, green: 0.62, blue: 0.2)
                                                  : Color.primary.opacity(pinHovering ? 0.7 : 0.4))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { pinHovering = $0 }
                .help(isPinned ? "Unpin: follow me across desktops" : "Pin to this desktop")
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 36)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
        }
    }
}

/// One item in the top toolbar: an icon, highlighted when it is the current view. Its name
/// appears in a small label underneath after a short hover. (A system tooltip is unreliable
/// here: the panel never activates the app, and macOS shows tooltips only for active apps.)
struct ToolbarTab: View {
    let icon: String
    let label: String
    let isActive: Bool
    let action: () -> Void
    @State private var hovering = false
    @State private var showLabel = false
    @State private var pendingLabel: DispatchWorkItem?

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Color.primary.opacity(isActive ? 0.95 : (hovering ? 0.8 : 0.5)))
                .frame(width: 30, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(isActive ? 0.12 : (hovering ? 0.06 : 0)))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .onHover { inside in
            hovering = inside
            pendingLabel?.cancel()
            if inside {
                let work = DispatchWorkItem { withAnimation(.easeOut(duration: 0.12)) { showLabel = true } }
                pendingLabel = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
            } else {
                showLabel = false
            }
        }
        .overlay(alignment: .bottom) {
            if showLabel {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.black.opacity(0.85)))
                    .fixedSize()
                    .offset(y: 28)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
    }
}

/// An AppKit view that hands a mouse-down to the window's drag loop, so the borderless
/// panel can be moved by its grip bar.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}

    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }
    }
}

// MARK: - Resize grip

/// A small grip in the bottom-right corner: two diagonal strokes that brighten on hover.
/// Dragging it resizes the card with the top-left corner fixed.
struct CornerResizeHandle: View {
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            CornerResizeArea(hovering: $hovering)
            GripMarks()
                .stroke(Color.primary.opacity(hovering ? 0.55 : 0.25),
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .frame(width: 9, height: 9)
                .padding(5)
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
        .frame(width: 22, height: 22)
    }
}

/// Two diagonal strokes hugging the bottom-right corner.
struct GripMarks: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.move(to: CGPoint(x: rect.maxX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return p
    }
}

/// Tracks the drag in screen coordinates against the size at mouse-down. (The grip moves
/// with the window as it resizes, so view-relative drag offsets would feed back on themselves.)
struct CornerResizeArea: NSViewRepresentable {
    @Binding var hovering: Bool

    func makeNSView(context: Context) -> GripView {
        let view = GripView()
        view.onHover = { hovering = $0 }
        return view
    }
    func updateNSView(_ nsView: GripView, context: Context) {}

    final class GripView: NSView {
        var onHover: ((Bool) -> Void)?
        private var startMouse: NSPoint = .zero
        private var startSize: NSSize = .zero
        private var tracking: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
            addTrackingArea(area)
            tracking = area
        }
        override func mouseEntered(with event: NSEvent) { onHover?(true) }
        override func mouseExited(with event: NSEvent) { onHover?(false) }

        override func resetCursorRects() {
            if #available(macOS 15.0, *) {
                addCursorRect(bounds, cursor: .frameResize(position: .bottomRight, directions: .all))
            } else {
                addCursorRect(bounds, cursor: .crosshair)
            }
        }

        override func mouseDown(with event: NSEvent) {
            startMouse = NSEvent.mouseLocation
            startSize = window?.frame.size ?? .zero
        }

        override func mouseDragged(with event: NSEvent) {
            let now = NSEvent.mouseLocation
            // Screen y grows upward: dragging down (smaller y) makes the card taller.
            PluckkPanel.shared?.resize(width: startSize.width + (now.x - startMouse.x),
                                       height: startSize.height - (now.y - startMouse.y))
        }
    }
}

#Preview {
    SidebarView(isExpanded: true, panelWidth: 600)
        .frame(width: 600, height: 400)
        .preferredColorScheme(.dark)
}
