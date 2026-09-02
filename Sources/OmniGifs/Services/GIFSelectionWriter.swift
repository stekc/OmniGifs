import AppKit
import ApplicationServices

enum GIFSelectionWriter {
    struct PasteboardTransaction {
        fileprivate let savedItems: [NSPasteboardItem]
        fileprivate let temporaryChangeCount: Int
    }

    @discardableResult
    static func copySourceURL(
        of favorite: GIFFavorite,
        to pasteboard: NSPasteboard = .general
    ) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(favorite.sourceURL.absoluteString, forType: .string)
    }

    /// Requires Accessibility trust to reach the focused control in another app.
    @MainActor
    @discardableResult
    static func pasteSourceURL(
        of favorite: GIFFavorite,
        to pasteboard: NSPasteboard = .general
    ) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let value = favorite.sourceURL.absoluteString
        if insertUsingAccessibility(value) { return true }

        guard let transaction = prepareTemporaryURL(value, on: pasteboard) else {
            return false
        }
        guard sendPasteKeystroke() else {
            _ = restorePasteboardIfUnchanged(transaction, on: pasteboard)
            return false
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            _ = restorePasteboardIfUnchanged(transaction, on: pasteboard)
        }
        return true
    }

    static func prepareTemporaryURL(
        _ value: String,
        on pasteboard: NSPasteboard
    ) -> PasteboardTransaction? {
        guard let savedItems = snapshot(pasteboard) else { return nil }
        pasteboard.clearContents()
        guard pasteboard.setString(value, forType: .string) else {
            pasteboard.clearContents()
            pasteboard.writeObjects(savedItems)
            return nil
        }
        return PasteboardTransaction(
            savedItems: savedItems,
            temporaryChangeCount: pasteboard.changeCount
        )
    }

    @discardableResult
    static func restorePasteboardIfUnchanged(
        _ transaction: PasteboardTransaction,
        on pasteboard: NSPasteboard
    ) -> Bool {
        guard pasteboard.changeCount == transaction.temporaryChangeCount else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects(transaction.savedItems)
    }

    private static func insertUsingAccessibility(_ value: String) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        let copyResult = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )
        guard copyResult == .success,
            let focusedValue,
            CFGetTypeID(focusedValue) == AXUIElementGetTypeID()
        else { return false }

        let focusedElement = unsafeDowncast(focusedValue, to: AXUIElement.self)
        var isSettable = DarwinBoolean(false)
        let settableResult = AXUIElementIsAttributeSettable(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &isSettable
        )
        guard settableResult == .success, isSettable.boolValue else { return false }
        return AXUIElementSetAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            value as CFString
        ) == .success
    }

    private static func sendPasteKeystroke() -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 0x09
        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else { return false }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
        return true
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem]? {
        var copies: [NSPasteboardItem] = []
        for item in pasteboard.pasteboardItems ?? [] {
            let copy = NSPasteboardItem()
            for type in item.types {
                guard let data = item.data(forType: type) else { return nil }
                copy.setData(data, forType: type)
            }
            copies.append(copy)
        }
        return copies
    }
}
