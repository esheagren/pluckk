import AppKit
import SwiftUI

struct SidebarView: View {
    let isExpanded: Bool
    var panelWidth: CGFloat = 600
    var isPinned: Bool = false
    @ObservedObject private var appState = AppState.shared
    @Environment(\.colorScheme) var colorScheme

    private var backgroundColor: Color {
        colorScheme == .dark ? PluckkTheme.Dark.background : PluckkTheme.Light.background
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
            // Background color
            backgroundColor.ignoresSafeArea()

            // Sand animation background (full panel)
            // allowsHitTesting(false) ensures clicks pass through to buttons
            SandAnimationView()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                GripBar(isPinned: isPinned)

                // Main content based on current view
                Group {
                    switch appState.currentView {
                    case .generate:
                        if appState.isAuthenticated {
                            CardGenerationView()
                        } else {
                            LoginView()
                        }
                    case .settings:
                        SettingsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Resize handles: left edge → width, bottom edge → height
            HStack { ResizeHandle(); Spacer() }
            VStack { Spacer(); BottomResizeHandle() }
        }
    }
}

// MARK: - Grip bar (move handle + close and pin buttons)

/// The strip across the top of the card. Dragging anywhere on it moves the window;
/// the red dot on the left closes (collapses) the panel; the pin on the right keeps the
/// card on the current desktop instead of following the user.
struct GripBar: View {
    let isPinned: Bool
    @State private var closeHovering = false
    @State private var pinHovering = false

    var body: some View {
        ZStack {
            WindowDragArea()

            Capsule()
                .fill(Color.white.opacity(0.25))
                .frame(width: 40, height: 4)
                .allowsHitTesting(false)

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
                                                  : Color.white.opacity(pinHovering ? 0.7 : 0.4))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { pinHovering = $0 }
                .help(isPinned ? "Unpin: follow me across desktops" : "Pin to this desktop")
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 26)
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

// MARK: - Resize Handles

struct ResizeHandle: View {
    @Environment(\.colorScheme) var colorScheme
    @State private var isHovering = false
    @State private var isDragging = false

    private var handleColor: Color {
        if isDragging {
            return colorScheme == .dark ? Color.white.opacity(0.5) : Color.black.opacity(0.4)
        } else if isHovering {
            return colorScheme == .dark ? Color.white.opacity(0.35) : Color.black.opacity(0.25)
        } else {
            return colorScheme == .dark ? Color.white.opacity(0.2) : Color.black.opacity(0.15)
        }
    }

    var body: some View {
        // Invisible hit area with pill indicator on hover
        Color.clear
            .frame(width: 12)
            .contentShape(Rectangle())
            .overlay(
                // Vertical pill indicator - only visible on hover/drag
                RoundedRectangle(cornerRadius: 2)
                    .fill(handleColor)
                    .frame(width: 4, height: 40)
                    .opacity(isHovering || isDragging ? 1 : 0)
                    .animation(.easeInOut(duration: 0.15), value: isHovering)
            )
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        isDragging = true
                        // Dragging left (negative x) = wider panel
                        if let panel = PluckkPanel.shared {
                            panel.resize(to: panel.expandedWidth - value.translation.width)
                        }
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
    }
}

struct BottomResizeHandle: View {
    @Environment(\.colorScheme) var colorScheme
    @State private var isHovering = false
    @State private var isDragging = false

    private var handleColor: Color {
        if isDragging {
            return colorScheme == .dark ? Color.white.opacity(0.5) : Color.black.opacity(0.4)
        } else if isHovering {
            return colorScheme == .dark ? Color.white.opacity(0.35) : Color.black.opacity(0.25)
        } else {
            return colorScheme == .dark ? Color.white.opacity(0.2) : Color.black.opacity(0.15)
        }
    }

    var body: some View {
        Color.clear
            .frame(height: 10)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .fill(handleColor)
                    .frame(width: 40, height: 4)
                    .opacity(isHovering || isDragging ? 1 : 0)
                    .animation(.easeInOut(duration: 0.15), value: isHovering)
            )
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        isDragging = true
                        // Dragging down (positive y) = taller panel, top edge stays put
                        if let panel = PluckkPanel.shared {
                            panel.resizeHeight(to: panel.expandedHeight + value.translation.height)
                        }
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
    }
}

#Preview {
    SidebarView(isExpanded: true, panelWidth: 600)
        .frame(width: 600, height: 400)
        .preferredColorScheme(.dark)
}
