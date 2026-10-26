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
    private let maxExpandedWidth: CGFloat = 900
    private let minExpandedHeight: CGFloat = 280
    private let maxExpandedHeight: CGFloat = 900
    private let bottomMargin: CGFloat = 8
    private let cursorGap: CGFloat = 16
    private(set) var expandedWidth: CGFloat = 600
    private(set) var expandedHeight: CGFloat = 400

    private(set) var isExpanded = false
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
        let sidebarView = SidebarView(isExpanded: isExpanded, panelWidth: expandedWidth, isPinned: isPinned)
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
        let size = NSSize(width: expandedWidth, height: expandedHeight)
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
        }

        updateHostingView()
    }

    func collapse() {
        guard isExpanded else { return }
        isExpanded = false
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

        // Reset state when collapsing
        AppState.shared.reset()
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
        hostingView?.rootView = SidebarView(isExpanded: isExpanded, panelWidth: expandedWidth, isPinned: isPinned)
    }

    // MARK: - Resizing (one grip in the bottom-right corner; the top-left corner stays put)

    func resize(width: CGFloat, height: CGFloat) {
        guard isExpanded else { return }
        let newWidth = clampWidth(width)
        let newHeight = clampHeight(height)
        var f = frame
        f.origin.y = f.maxY - newHeight
        f.size = NSSize(width: newWidth, height: newHeight)
        expandedWidth = newWidth
        expandedHeight = newHeight
        setFrame(f, display: true)
        saveSize()
        updateHostingView()
    }
}
