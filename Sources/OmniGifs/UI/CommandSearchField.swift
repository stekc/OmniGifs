import AppKit

final class CommandSearchField: NSSearchField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([
            .command, .option, .control, .shift,
        ])
        guard modifiers == .command,
            event.charactersIgnoringModifiers?.lowercased() == "a"
        else {
            return super.performKeyEquivalent(with: event)
        }

        if currentEditor() == nil {
            window?.makeFirstResponder(self)
        }
        guard let editor = currentEditor() else {
            return super.performKeyEquivalent(with: event)
        }
        editor.selectAll(nil)
        return true
    }
}
