import AppKit
import Testing

@testable import OmniGifs

@MainActor
struct CommandSearchFieldTests {
    @Test func commandASelectsTheEntireSearchQuery() throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let field = CommandSearchField(frame: NSRect(x: 10, y: 20, width: 380, height: 30))
        field.stringValue = "lorem ipsum dolor"
        window.contentView?.addSubview(field)
        window.makeFirstResponder(field)
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: .command,
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "a",
                charactersIgnoringModifiers: "a",
                isARepeat: false,
                keyCode: 0
            ))

        #expect(field.performKeyEquivalent(with: event))
        #expect(field.currentEditor()?.selectedRange == NSRange(location: 0, length: 17))
    }
}
