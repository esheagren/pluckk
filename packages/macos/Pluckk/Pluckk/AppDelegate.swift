import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: PluckkPanel!
    var statusItem: NSStatusItem!
    var doubleCmdDetector: DoubleCmdDetector!
    var selectionReader: SelectionReader!

    @ObservedObject var appState = AppState.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Check accessibility permissions
        if !checkAccessibilityPermissions() {
            showPermissionsWindow()
        }

        // Request Automation permission for System Events (needed for window resizing fallback)
        WindowResizer.shared.requestAutomationPermission()

        setupPanel()
        setupMenuBar()
        setupDoubleCmdDetector()
        selectionReader = SelectionReader()

        // Hide dock icon (we're a menu bar app)
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationWillTerminate(_ notification: Notification) {
        doubleCmdDetector?.stop()
    }

    // MARK: - Setup

    private func setupPanel() {
        panel = PluckkPanel()
        panel.setup()
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "rectangle.stack.fill", accessibilityDescription: "Pluckk")
            button.action = #selector(menuBarClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    private func setupDoubleCmdDetector() {
        doubleCmdDetector = DoubleCmdDetector()
        doubleCmdDetector.onDoubleTap = { [weak self] in
            self?.handleDoubleTap()
        }
        // Holding ⌘ on its own sends the card back down to the pill (no-op if already there).
        doubleCmdDetector.onLongHold = { [weak self] in
            self?.panel.collapse()
        }
        doubleCmdDetector.start()
    }

    // MARK: - Actions

    @objc private func menuBarClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePanel()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()

        menu.addItem(NSMenuItem(title: "Open pluckk.app", action: #selector(openWebapp), keyEquivalent: "o"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Pluckk", action: #selector(quit), keyEquivalent: "q"))

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openWebapp() {
        if let url = URL(string: Config.webappURL) { NSWorkspace.shared.open(url) }
    }

    @objc private func showSettings() {
        appState.currentView = .settings
        WindowResizer.shared.captureTargetWindow()
        panel.expand()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func togglePanel() {
        if panel.isExpanded {
            panel.collapse()
        } else {
            WindowResizer.shared.captureTargetWindow()
            panel.expand()
        }
    }

    private func handleDoubleTap() {
        print("AppDelegate: handleDoubleTap called, panel.isExpanded=\(panel.isExpanded)")

        // Try to get selected text via Accessibility API first
        // This works even when panel is expanded since it reads from the frontmost app.
        // Electron apps (Notion, Slack) expose no focused element, so fall back to copying the
        // selection — unless our own panel is key, in which case ⌘C would land on us.
        let selected = selectionReader.getSelectedText().flatMap { $0.isEmpty ? nil : $0 }
            ?? (panel.isKeyWindow ? nil : selectionReader.copySelection())
        if let selectedText = selected {
            print("AppDelegate: Found selected text, capturing for card generation")

            // Only capture window if panel isn't expanded yet
            if !panel.isExpanded {
                WindowResizer.shared.captureTargetWindow()
            }

            let context = selectionReader.getSourceContext()
            appState.capturedContent = .text(selectedText)
            appState.sourceContext = context
            appState.currentView = .generate

            if !panel.isExpanded {
                panel.expand()
            }
            return
        }

        // If panel is expanded and no text selected, collapse it
        if panel.isExpanded {
            print("AppDelegate: Panel is expanded, no text selected, collapsing")
            panel.collapse()
            return
        }

        // Nothing selected: open on Practice. No clipboard fallback (text or image): the
        // clipboard is usually stale, and it silently produced cards about the wrong thing.
        // A clipboard screenshot is offered on the Create tab instead.
        WindowResizer.shared.captureTargetWindow()
        appState.capturedContent = nil
        appState.currentView = .practice
        PracticeSession.shared.refreshIfFinished()
        panel.expand()
    }

    // MARK: - Permissions

    private func checkAccessibilityPermissions() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private func showPermissionsWindow() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = "Pluckk needs accessibility permission to capture text selections and detect the double-tap ⌘ shortcut.\n\nClick 'Open Settings' to grant permission, then restart Pluckk."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // Request permission (this will show the system prompt)
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
    }
}
