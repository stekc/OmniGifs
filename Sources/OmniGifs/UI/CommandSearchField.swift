import AppKit

final class CommandSearchField: NSSearchField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([
            .command, .option, .control, .shift,
        ])
        guard modifiers == .command || modifiers == [.command, .shift] else {
            return super.performKeyEquivalent(with: event)
        }

        let action: Selector?
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "x" where modifiers == .command: action = #selector(NSText.cut(_:))
        case "c" where modifiers == .command: action = #selector(NSText.copy(_:))
        case "v" where modifiers == .command: action = #selector(NSText.paste(_:))
        case "a" where modifiers == .command: action = #selector(NSText.selectAll(_:))
        case "z": action = Selector(modifiers.contains(.shift) ? "redo:" : "undo:")
        default: action = nil
        }
        guard let action else { return super.performKeyEquivalent(with: event) }

        if currentEditor() == nil {
            window?.makeFirstResponder(self)
        }
        guard let editor = currentEditor() else {
            return super.performKeyEquivalent(with: event)
        }
        return NSApp.sendAction(action, to: editor, from: self)
    }
}
