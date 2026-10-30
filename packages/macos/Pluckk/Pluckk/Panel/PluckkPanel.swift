import AppKit
import SwiftUI

/// Two behaviours in one window:
///  - Collapsed: a pill at the bottom-centre of whichever screen the user last clicked on.
///  - Expanded: a landscape card (3:2 by default) that opens at the cursor and then stays
///    put until the user drags it by its grip bar. Size persists; position does not.
///    It follows the user across desktops unless pinned.
class PluckkPanel: NSPanel {
    // Shared instance for easy access from SwiftUI views
    static var shared: PluckkPanel?

    private let collapsedWidth: CGFloat = 64
    private let collapsedHeight: CGFloat = 6
    private let minExpandedWidth: CGFloat = 440
    private let maxExpandedWidth: CGFloat = 6000
    private let minExpandedHeight: CGFloat = 280
    private let maxExpandedHeight: CGFloat = 4000
    private let bottomMargin: CGFloat = 8
    private let cursorGap: CGFloat = 16
    private(set) var expandedWidth: CGFloat = 600
    private(set) var expandedHeight: CGFloat = 400

    private(set) var isExpanded = false
    /// Green button: the card is in full screen (see toggleFill).
    private(set) var isFilling = false
    private var fullScreenWindow: NSWindow?
    private var collapseAfterFullScreen: Bool?
    /// The window holding the card right now.
    var hostWindow: NSWindow { fullScreenWindow ?? self }
    /// The assistant panel on the card's right. The window grows to make room, so the card itself
    /// keeps its size.
    private(set) var isAssistantOpen = UserDefaults.standard.bool(forKey: "assistantOpen")
    static let assistantWidth: CGFloat = 360
    private var assistantRoom: CGFloat { isAssistantOpen ? Self.assistantWidth : 0 }
    private var frameBeforeFill: NSRect?
    private var hostingView: NSHostingView<SidebarView>?

    /// Screen the pill currently sits on, tracked by frame (NSScreen objects are recreated).
    private var pillScreenFrame: NSRect = .zero
    private var clickMonitor: Any?

    private enum Keys {
        static let width = "panelWidth", height = "panelHeight"
    }

    /// Off by default: the panel floats over the active app. Turning it on shoves the
    /// frontmost window aside (and pulls it out of full screen), which is intrusive on
    /// narrow or portrait displays.
    static let pushWindowAsideKey = "pushWindowAside"
    private var pushesWindowAside: Bool { UserDefaults.standard.bool(forKey: Self.pushWindowAsideKey) }

    /// Pinned: the expanded card belongs to the desktop (Space) it was pinned on instead of
    /// following the user to every desktop. The pill always follows. Persists across launches.
    static let pinnedKey = "panelPinned"
    private(set) var isPinned = UserDefaults.standard.bool(forKey: PluckkPanel.pinnedKey)

    private static let followBehavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    private static let pinnedBehavior: NSWindow.CollectionBehavior = [.managed, .fullScreenAuxiliary]

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
    }

    // Allow panel to become key window for button clicks
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func setup() {
        // Set shared instance for access from SwiftUI views
        PluckkPanel.shared = self
        restoreSize()

        // Panel configuration. The style mask must be borderless BEFORE the frame is set:
        // NSPanel() starts out titled, and a titled window clamps a 12pt-tall frame to a
        // zero-height content rect, which then becomes the whole frame once borderless.
        level = .floating
        styleMask = [.borderless, .nonactivatingPanel]
        setFrame(collapsedFrame(on: screenUnderMouse()), display: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false  // Allow becoming key to receive clicks
        acceptsMouseMovedEvents = true
        isMovableByWindowBackground = false  // moved only via the grip bar

        // Appear on all spaces (unless the card is pinned) and work with full-screen apps
        applySpaceBehavior()

        // Set up content view
        let sidebarView = SidebarView(isExpanded: isExpanded, panelWidth: expandedWidth, isPinned: isPinned, isFilling: isFilling, isAssistantOpen: isAssistantOpen)
        hostingView = NSHostingView(rootView: sidebarView)
        // The panel's size is decided here, never by SwiftUI.
        hostingView?.sizingOptions = []
        hostingView?.frame = contentView?.bounds ?? .zero
        hostingView?.autoresizingMask = [.width, .height]
        contentView = hostingView

        // Show the panel
        orderFrontRegardless()

        // Keep the panel on a screen if displays are added/removed
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // The pill follows the screen the user is working on, judged by where they click.
        // Global monitors never see clicks on our own window, so the card is unaffected.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.movePillToClickedScreen()
        }
    }

    // MARK: - Size persistence

    private func restoreSize() {
        let d = UserDefaults.standard
        if d.object(forKey: Keys.width) != nil {
            expandedWidth = clampWidth(CGFloat(d.double(forKey: Keys.width)))
            expandedHeight = clampHeight(CGFloat(d.double(forKey: Keys.height)))
        }
    }

    private func saveSize() {
        let d = UserDefaults.standard
        d.set(Double(expandedWidth), forKey: Keys.width)
        d.set(Double(expandedHeight), forKey: Keys.height)
    }

    private func clampWidth(_ w: CGFloat) -> CGFloat { min(max(w, minExpandedWidth), maxExpandedWidth) }
    private func clampHeight(_ h: CGFloat) -> CGFloat { min(max(h, minExpandedHeight), maxExpandedHeight) }

    // MARK: - Screens and placement

    private func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    }

    private func screenUnderMouse() -> NSScreen? {
        screen(containing: NSEvent.mouseLocation) ?? NSScreen.main
    }

    /// Keep a frame entirely inside the visible area of a screen (below the menu bar, above the Dock).
    private func clamped(_ rect: NSRect, to screen: NSScreen?) -> NSRect {
        guard let area = screen?.visibleFrame else { return rect }
        var r = rect
        r.size.width = min(r.width, area.width)
        r.size.height = min(r.height, area.height)
        r.origin.x = min(max(r.minX, area.minX), area.maxX - r.width)
        r.origin.y = min(max(r.minY, area.minY), area.maxY - r.height)
        return r
    }

    /// Bottom-centre of the given screen.
    private func collapsedFrame(on screen: NSScreen?) -> NSRect {
        pillScreenFrame = screen?.frame ?? .zero
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(x: area.midX - collapsedWidth / 2, y: area.minY + bottomMargin,
                      width: collapsedWidth, height: collapsedHeight)
    }

    /// The card opens centred under the cursor; if there is no room below, it opens above.
    private func expandedFrameAtCursor() -> NSRect {
        let mouse = NSEvent.mouseLocation
        let target = screen(containing: mouse) ?? NSScreen.main
        let area = target?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: expandedWidth + assistantRoom, height: expandedHeight)
        var origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y - cursorGap - size.height)
        if origin.y < area.minY {
            origin.y = mouse.y + cursorGap
        }
        return clamped(NSRect(origin: origin, size: size), to: target)
    }

    private func movePillToClickedScreen() {
        guard !isExpanded, let s = screenUnderMouse(), s.frame != pillScreenFrame else { return }
        setFrame(collapsedFrame(on: s), display: true)
    }

    @objc private func screenParametersChanged() {
        if isFilling { return }
        if isExpanded {
            let centre = NSPoint(x: frame.midX, y: frame.midY)
            setFrame(clamped(frame, to: screen(containing: centre) ?? NSScreen.main), display: true)
        } else {
            setFrame(collapsedFrame(on: screenUnderMouse()), display: true)
        }
    }

    // MARK: - Pinning

    func togglePinned() {
        isPinned.toggle()
        UserDefaults.standard.set(isPinned, forKey: Self.pinnedKey)
        // Changing the behaviour while visible attaches the card to the current desktop.
        applySpaceBehavior()
        updateHostingView()
    }

    private func applySpaceBehavior() {
        collectionBehavior = isExpanded && isPinned ? Self.pinnedBehavior : Self.followBehavior
    }

    // MARK: - Expand / collapse

    func expand() {
        guard !isExpanded else { return }
        isExpanded = true
        applySpaceBehavior()
        PracticeSession.shared.refreshTodayCounts()

        if pushesWindowAside {
            WindowResizer.shared.makeRoomForPanel(panelWidth: expandedWidth)
        }

        let newFrame = expandedFrameAtCursor()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().setFrame(newFrame, display: true)
        } completionHandler: {
            // Make panel key so buttons receive clicks
            self.makeKey()
            // AppKit focuses the first text field it finds, which would be the assistant's box.
            if self.isAssistantOpen, AppState.shared.currentView == .practice, !PracticeSession.shared.editing {
                self.makeFirstResponder(nil)
            }
        }

        updateHostingView()
    }

    /// Yellow button: down to the pill, keeping what's on the card (captured text, generated
    /// cards, the current view) for when it opens again.
    func minimize() { collapse(resetState: false) }

    /// Red button (and ⌘⌘ / hold-⌘): down to the pill, clearing the capture.
    func collapse() { collapse(resetState: true) }

    func toggleAssistant() {
        guard isExpanded else { return }
        isAssistantOpen.toggle()
        AssistantSession.shared.wantsFocus = isAssistantOpen
        UserDefaults.standard.set(isAssistantOpen, forKey: "assistantOpen")
        if !isFilling {
            var target = frame
            target.size.width += isAssistantOpen ? Self.assistantWidth : -Self.assistantWidth
            let centre = NSPoint(x: frame.midX, y: frame.midY)
            setFrame(clamped(target, to: screen(containing: centre) ?? NSScreen.main), display: true, animate: true)
        }
        updateHostingView()
    }

    /// Green button: real full screen, in its own Space, so swiping between apps reaches it. A
    /// floating non-activating panel can't do that, so the card moves into an ordinary window
    /// for as long as it lasts and comes back when full screen ends, however it ends.
    func toggleFill() {
        guard isExpanded else { return }
        if let fullScreenWindow {
            fullScreenWindow.toggleFullScreen(nil)
            return
        }
        frameBeforeFill = frame
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = backgroundColor
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        NotificationCenter.default.addObserver(self, selector: #selector(fullScreenEnded),
                                               name: NSWindow.didExitFullScreenNotification, object: window)
        contentView = NSView()
        window.contentView = hostingView
        fullScreenWindow = window
        isFilling = true
        orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.toggleFullScreen(nil)
        updateHostingView()
    }

    @objc private func fullScreenEnded() {
        guard let window = fullScreenWindow else { return }
        NotificationCenter.default.removeObserver(self, name: NSWindow.didExitFullScreenNotification, object: window)
        fullScreenWindow = nil
        isFilling = false
        window.contentView = NSView()
        contentView = hostingView
        window.orderOut(nil)
        if let frameBeforeFill { setFrame(frameBeforeFill, display: true) }
        orderFrontRegardless()
        makeKey()
        updateHostingView()
        if let reset = collapseAfterFullScreen {
            collapseAfterFullScreen = nil
            collapse(resetState: reset)
        }
    }

    private func collapse(resetState: Bool) {
        guard isExpanded else { return }
        if let fullScreenWindow {
            collapseAfterFullScreen = resetState
            fullScreenWindow.toggleFullScreen(nil)
            return
        }
        isExpanded = false
        isFilling = false
        applySpaceBehavior()

        // No-op unless expand() resized a window
        WindowResizer.shared.restoreWindow()

        // The pill returns to the bottom-centre of the screen the card was on.
        let centre = NSPoint(x: frame.midX, y: frame.midY)
        let newFrame = collapsedFrame(on: screen(containing: centre) ?? screenUnderMouse())

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().setFrame(newFrame, display: true)
        }

        // Reset state when collapsing (not when minimising)
        if resetState { AppState.shared.reset() }
        PracticeSession.shared.panelClosed()
        updateHostingView()
    }

    func toggle() {
        if isExpanded {
            collapse()
        } else {
            expand()
        }
    }

    private func updateHostingView() {
        hostingView?.rootView = SidebarView(isExpanded: isExpanded, panelWidth: expandedWidth, isPinned: isPinned, isFilling: isFilling, isAssistantOpen: isAssistantOpen)
    }

    // MARK: - Resizing (from any edge or corner; the opposite side stays put)

    func resize(from start: NSRect, edges: ResizeEdges, dx: CGFloat, dy: CGFloat) {
        guard isExpanded, !isFilling else { return }
        var f = start
        if edges.contains(.right) { f.size.width = clampWidth(start.width + dx - assistantRoom) + assistantRoom }
        if edges.contains(.left) {
            f.size.width = clampWidth(start.width - dx - assistantRoom) + assistantRoom
            f.origin.x = start.maxX - f.width
        }
        if edges.contains(.top) { f.size.height = clampHeight(start.height + dy) }
        if edges.contains(.bottom) {
            f.size.height = clampHeight(start.height - dy)
            f.origin.y = start.maxY - f.height
        }
        expandedWidth = f.width - assistantRoom
        expandedHeight = f.height
        setFrame(f, display: true)
        saveSize()
        updateHostingView()
    }
}
