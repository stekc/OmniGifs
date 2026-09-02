import AppKit

enum GIFSelectionWriter {
    @discardableResult
    static func copySourceURL(
        of favorite: GIFFavorite,
        to pasteboard: NSPasteboard = .general
    ) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(favorite.sourceURL.absoluteString, forType: .string)
    }

    /// Requires Accessibility trust to reach other apps.
    @MainActor
    static func pasteSourceURL(
        of favorite: GIFFavorite,
        to pasteboard: NSPasteboard = .general
    ) {
        let saved = snapshot(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(favorite.sourceURL.absoluteString, forType: .string)
        sendPasteKeystroke()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            restore(saved, to: pasteboard)
        }
    }

    private static func sendPasteKeystroke() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 0x09
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cgAnnotatedSessionEventTap)
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    private static func restore(_ items: [NSPasteboardItem], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
    }
}
