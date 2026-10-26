import AppKit
import ApplicationServices

class SelectionReader {

    /// Gets the currently selected text from the frontmost application using Accessibility API
    func getSelectedText() -> String? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              let pid = frontApp.processIdentifier as pid_t? else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(pid)

        // Get the focused element
        var focusedElement: CFTypeRef?
        let focusResult = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )

        guard focusResult == .success,
              let focused = focusedElement else {
            return nil
        }

        // AXUIElement is a CFTypeRef, cast is always valid when API succeeds
        let focusedAX = focused as! AXUIElement

        // Try to get selected text directly
        var selectedText: CFTypeRef?
        let selectResult = AXUIElementCopyAttributeValue(
            focusedAX,
            kAXSelectedTextAttribute as CFString,
            &selectedText
        )

        if selectResult == .success,
           let text = selectedText as? String,
           !text.isEmpty {
            return text
        }

        // Fallback: try selected text range method
        return trySelectedTextRange(from: focusedAX)
    }

    /// Alternative method using text range
    private func trySelectedTextRange(from element: AXUIElement) -> String? {
        var selectedRange: CFTypeRef?
        let rangeResult = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRange
        )

        guard rangeResult == .success else {
            return nil
        }

        var selectedText: CFTypeRef?
        let textResult = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            selectedRange!,
            &selectedText
        )

        if textResult == .success, let text = selectedText as? String {
            return text
        }

        return nil
    }

    /// Gets image from the clipboard
    func getClipboardImage() -> NSImage? {
        let pasteboard = NSPasteboard.general

        // Check for image types in order of preference
        let imageTypes: [NSPasteboard.PasteboardType] = [
            .tiff,
            .png,
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("com.apple.pict")
        ]

        for type in imageTypes {
            if let data = pasteboard.data(forType: type),
               let image = NSImage(data: data) {
                return image
            }
        }

        // Try reading as file URL (e.g., screenshot file)
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let url = urls.first,
           let image = NSImage(contentsOf: url) {
            return image
        }

        return nil
    }

    /// Gets source context (app name and window title) from frontmost application
    func getSourceContext() -> SourceContext {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return SourceContext(appName: "Unknown", windowTitle: "")
        }

        let appName = frontApp.localizedName ?? "Unknown"
        let pid = frontApp.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        // Get focused window title
        var focusedWindow: CFTypeRef?
        let windowResult = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindow
        )

        var windowTitle = ""
        if windowResult == .success,
           let window = focusedWindow {
            // AXUIElement is a CFTypeRef, cast is always valid when API succeeds
            let windowAX = window as! AXUIElement
            var title: CFTypeRef?
            let titleResult = AXUIElementCopyAttributeValue(
                windowAX,
                kAXTitleAttribute as CFString,
                &title
            )
            if titleResult == .success, let titleString = title as? String {
                windowTitle = titleString
            }
        }

        return SourceContext(appName: appName, windowTitle: windowTitle)
    }

    /// Copies the frontmost app's selection with a synthetic ⌘C and returns it, then puts the
    /// clipboard back as it was. For apps that don't expose their text to Accessibility
    /// (Electron apps such as Notion and Slack). Returns nil unless the copy actually changed
    /// the clipboard, so stale clipboard text is never mistaken for the selection.
    func copySelection() -> String? {
        let pasteboard = NSPasteboard.general
        let saved: [NSPasteboardItem] = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        let before = pasteboard.changeCount

        postCommandC()

        // The target app copies asynchronously; give it up to ~300ms.
        var copied: String?
        for _ in 0..<30 {
            usleep(10_000)
            if pasteboard.changeCount != before {
                copied = pasteboard.string(forType: .string)
                break
            }
        }

        if pasteboard.changeCount != before {
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }

        guard let text = copied, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// ⌘C as a single key event carrying the Command flag (no separate ⌘ key events, which the
    /// double-tap detector would otherwise see).
    private func postCommandC() {
        let source = CGEventSource(stateID: .hidSystemState)
        let cKeyCode: CGKeyCode = 0x08
        let down = CGEvent(keyboardEventSource: source, virtualKey: cKeyCode, keyDown: true)
        down?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: source, virtualKey: cKeyCode, keyDown: false)
        up?.flags = .maskCommand
        up?.post(tap: .cghidEventTap)
    }
}
