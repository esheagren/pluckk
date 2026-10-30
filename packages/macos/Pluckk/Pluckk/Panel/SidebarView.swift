import AppKit
import SwiftUI

struct SidebarView: View {
    let isExpanded: Bool
    var panelWidth: CGFloat = 600
    var isPinned: Bool = false
    var isFilling: Bool = false
    var isAssistantOpen: Bool = false
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
                GripBar(isPinned: isPinned, isFilling: isFilling, isAssistantOpen: isAssistantOpen)
                    .zIndex(1)  // hover labels draw over the content below

                HStack(spacing: 0) {
                    NavRail()
                        .zIndex(1)  // hover labels draw over the content beside it

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
                    case .newCard:
                        if appState.isAuthenticated {
                            NewCardView()
                        } else {
                            LoginView()
                        }
                    case .decks:
                        if appState.isAuthenticated {
                            DecksView()
                        } else {
                            LoginView()
                        }
                    case .statistics:
                        if appState.isAuthenticated {
                            StatisticsView()
                        } else {
                            LoginView()
                        }
                    case .terminal:
                        TerminalPanelView()
                    case .settings:
                        SettingsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if isAssistantOpen {
                        Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1)
                        AssistantView().frame(width: PluckkPanel.assistantWidth - 1)
                    }
                }
            }

            if !isFilling { WindowEdgeHandles() }
        }
    }
}

// MARK: - Grip bar (move handle + close and pin buttons)

/// The strip across the top of the card. Dragging anywhere on it moves the window;
/// the red dot on the left closes (collapses) the panel; the pin on the right keeps the
/// card on the current desktop instead of following the user. Between them sits the
/// practice timer. (Navigation is the rail on the left; see NavRail.)
struct GripBar: View {
    let isPinned: Bool
    let isFilling: Bool
    let isAssistantOpen: Bool
    @State private var assistantHovering = false
    @State private var closeHovering = false
    @State private var pinHovering = false

    var body: some View {
        ZStack {
            WindowDragArea()

            SessionTimerView()

            HStack {
                // Red / yellow / green, as on any Mac window; their glyphs show while hovering
                // the group.
                HStack(spacing: 8) {
                    TrafficLight(color: Color(red: 1.0, green: 0.37, blue: 0.34), glyph: "xmark",
                                 showGlyph: closeHovering, help: "Close") {
                        PluckkPanel.shared?.collapse()
                    }
                    TrafficLight(color: Color(red: 1.0, green: 0.74, blue: 0.18), glyph: "minus",
                                 showGlyph: closeHovering, help: "Minimise (keeps your place)") {
                        PluckkPanel.shared?.minimize()
                    }
                    TrafficLight(color: Color(red: 0.16, green: 0.79, blue: 0.25),
                                 glyph: isFilling ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                 showGlyph: closeHovering, help: isFilling ? "Exit full screen" : "Full screen") {
                        PluckkPanel.shared?.toggleFill()
                    }
                }
                .onHover { closeHovering = $0 }
                Spacer()
                Button(action: { PluckkPanel.shared?.toggleAssistant() }) {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(isAssistantOpen ? PluckkTheme.accent : Color.primary.opacity(assistantHovering ? 0.7 : 0.4))
                        .frame(width: 22, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { assistantHovering = $0 }
                .help(isAssistantOpen ? "Close the assistant" : "Open the assistant")
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

/// The thin icon rail on the left: Mixed practice (the default; leaves any single-deck focus), Create (AI), New card (by hand), Decks;
/// Settings at the foot.
/// Hovering an icon slides its name out to the right (RailTab).
struct NavRail: View {
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var practice = PracticeSession.shared

    var body: some View {
        VStack(spacing: 6) {
            // Always the mix of every deck: leaves a single-deck focus (started from Decks).
            RailTab(icon: "rectangle.stack", label: "Mixed practice",
                    isActive: appState.currentView == .practice && practice.focusDeck == nil) {
                if practice.focusDeck != nil { practice.leaveDeck() }
                appState.currentView = .practice
            }
            tab(.generate, icon: "sparkles", label: "Create")
            tab(.newCard, icon: "plus", label: "New card")
            tab(.decks, icon: "square.grid.2x2", label: "Decks")
            tab(.statistics, icon: "chart.pie", label: "Statistics")
            Spacer()
            tab(.settings, icon: "gearshape", label: "Settings")
        }
        .padding(.vertical, 12)
        .frame(width: 44)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1)
        }
    }

    private func tab(_ view: PanelView, icon: String, label: String) -> some View {
        RailTab(icon: icon, label: label, isActive: appState.currentView == view) {
            appState.currentView = view
        }
    }
}

/// One item in the left rail. At rest just the icon; on hover it slides out into a pill with
/// its name to the right, drawn inside the panel over the content. (The rail reserves only the
/// icon's width; the pill overflows to the right, and the rail sits above the content.)
struct RailTab: View {
    let icon: String
    let label: String
    let isActive: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let isDark = colorScheme == .dark
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 16)
                if hovering {
                    Text(label)
                        .font(.system(size: 12, weight: .semibold))
                        .fixedSize()
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .foregroundColor(Color.primary.opacity(isActive || hovering ? 0.95 : 0.5))
            .padding(.horizontal, 7)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? (isDark ? PluckkTheme.Dark.card : PluckkTheme.Light.card)
                                   : Color.primary.opacity(isActive ? 0.12 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(hovering ? (isDark ? PluckkTheme.Dark.cardBorder : PluckkTheme.Light.cardBorder) : .clear, lineWidth: 1)
            )
            .shadow(color: .black.opacity(hovering ? (isDark ? 0.4 : 0.1) : 0), radius: 6, y: 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        // Hover over the whole pill (label included), so moving onto the word doesn't close it.
        .onHover { inside in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) { hovering = inside }
        }
        .accessibilityLabel(label)
        .frame(width: 30, alignment: .leading)
    }
}

/// One window-control dot (red, yellow or green).
struct TrafficLight: View {
    let color: Color
    let glyph: String
    let showGlyph: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(color)
                Image(systemName: glyph)
                    .font(.system(size: 6.5, weight: .bold))
                    .foregroundColor(.black.opacity(0.6))
                    .opacity(showGlyph ? 1 : 0)
            }
            .frame(width: 12, height: 12)
        }
        .buttonStyle(.plain)
        .help(help)
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

// MARK: - Resizing

struct ResizeEdges: OptionSet {
    let rawValue: Int
    static let left = ResizeEdges(rawValue: 1)
    static let right = ResizeEdges(rawValue: 2)
    static let top = ResizeEdges(rawValue: 4)
    static let bottom = ResizeEdges(rawValue: 8)
}

/// Invisible strips along every edge and corner: the window resizes like any Mac window.
struct WindowEdgeHandles: View {
    private let edge: CGFloat = 5
    private let corner: CGFloat = 10

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                EdgeResizeArea(edges: .top).frame(height: edge)
                Spacer(minLength: 0)
                EdgeResizeArea(edges: .bottom).frame(height: edge)
            }
            HStack(spacing: 0) {
                EdgeResizeArea(edges: .left).frame(width: edge)
                Spacer(minLength: 0)
                EdgeResizeArea(edges: .right).frame(width: edge)
            }
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    EdgeResizeArea(edges: [.top, .left]).frame(width: corner, height: corner)
                    Spacer(minLength: 0)
                    EdgeResizeArea(edges: [.top, .right]).frame(width: corner, height: corner)
                }
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    EdgeResizeArea(edges: [.bottom, .left]).frame(width: corner, height: corner)
                    Spacer(minLength: 0)
                    EdgeResizeArea(edges: [.bottom, .right]).frame(width: corner, height: corner)
                }
            }
        }
    }
}

/// Tracks the drag in screen coordinates against the frame at mouse-down. (The strip moves
/// with the window as it resizes, so view-relative drag offsets would feed back on themselves.)
struct EdgeResizeArea: NSViewRepresentable {
    let edges: ResizeEdges

    func makeNSView(context: Context) -> EdgeView {
        let view = EdgeView()
        view.edges = edges
        return view
    }
    func updateNSView(_ nsView: EdgeView, context: Context) {}

    final class EdgeView: NSView {
        var edges: ResizeEdges = []
        private var startMouse: NSPoint = .zero
        private var startFrame: NSRect = .zero

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: cursor)
        }

        private var cursor: NSCursor {
            let sideways = edges.contains(.left) || edges.contains(.right)
            let upDown = edges.contains(.top) || edges.contains(.bottom)
            if #available(macOS 15.0, *) {
                let position: NSCursor.FrameResizePosition
                switch (edges.contains(.top), edges.contains(.bottom), edges.contains(.left), edges.contains(.right)) {
                case (true, _, true, _): position = .topLeft
                case (true, _, _, true): position = .topRight
                case (_, true, true, _): position = .bottomLeft
                case (_, true, _, true): position = .bottomRight
                case (true, _, _, _): position = .top
                case (_, true, _, _): position = .bottom
                case (_, _, true, _): position = .left
                default: position = .right
                }
                return .frameResize(position: position, directions: .all)
            }
            if sideways && upDown { return .crosshair }
            return sideways ? .resizeLeftRight : .resizeUpDown
        }

        override func mouseDown(with event: NSEvent) {
            startMouse = NSEvent.mouseLocation
            startFrame = window?.frame ?? .zero
        }

        override func mouseDragged(with event: NSEvent) {
            let now = NSEvent.mouseLocation
            PluckkPanel.shared?.resize(from: startFrame, edges: edges, dx: now.x - startMouse.x, dy: now.y - startMouse.y)
        }
    }
}

#Preview {
    SidebarView(isExpanded: true, panelWidth: 600)
        .frame(width: 600, height: 400)
        .preferredColorScheme(.dark)
}
