import AppKit

@MainActor
final class ShortcutRecorderButton: NSButton {
    var shortcut: GlobalShortcut {
        didSet {
            guard !isRecording else { return }
            title = shortcut.displayName
        }
    }
    var onShortcutChange: ((GlobalShortcut) -> Void)?

    private var isRecording = false

    init(shortcut: GlobalShortcut) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        title = shortcut.displayName
        bezelStyle = .rounded
        focusRingType = .exterior
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(beginRecording)
        toolTip = "Click, then type a keyboard shortcut"
        setAccessibilityLabel("Keyboard shortcut")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    @objc private func beginRecording() {
        isRecording = true
        title = "Type Shortcut"
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            stopRecording()
            return
        }
        guard let shortcut = GlobalShortcut(event: event) else {
            NSSound.beep()
            return
        }
        self.shortcut = shortcut
        stopRecording()
        onShortcutChange?(shortcut)
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { stopRecording() }
        return resigned
    }

    private func stopRecording() {
        isRecording = false
        title = shortcut.displayName
    }
}
