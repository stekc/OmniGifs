import AppKit
import ApplicationServices

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    typealias ShortcutConfigurationHandler = (Bool, GlobalShortcut) -> Bool

    private let settings: AppSettings
    private let configureShortcut: ShortcutConfigurationHandler
    private let requestAccessibilityAccess: () -> Bool

    private let autoPasteCheckbox = NSButton(
        checkboxWithTitle: "Paste GIF URLs automatically",
        target: nil,
        action: nil
    )
    private let autoPasteDescription = SettingsWindowController.descriptionLabel(
        "Paste the selected GIF’s URL into the previously active app without changing the "
            + "clipboard. This requires permission in Accessibility settings."
    )
    private let accessibilityStatus = SettingsWindowController.descriptionLabel("")
    private let shiftCheckbox = NSButton(
        checkboxWithTitle: "Use Shift to reverse the paste behavior",
        target: nil,
        action: nil
    )
    private let shiftDescription = SettingsWindowController.descriptionLabel(
        "When automatic pasting is off, hold Shift while choosing a GIF to paste it. When "
            + "automatic pasting is on, hold Shift to copy the URL instead."
    )
    private let shortcutCheckbox = NSButton(
        checkboxWithTitle: "Use a global keyboard shortcut",
        target: nil,
        action: nil
    )
    private let shortcutLabel = NSTextField(labelWithString: "Keyboard shortcut:")
    private let shortcutRecorder: ShortcutRecorderButton
    private let shortcutStatus = SettingsWindowController.descriptionLabel("")
    private let versionLabel = NSTextField(
        labelWithString: "Version \(SettingsWindowController.appVersion)"
    )
    private let repositoryButton = NSButton(
        title: "View on GitHub…",
        target: nil,
        action: nil
    )

    init(
        settings: AppSettings,
        configureShortcut: @escaping ShortcutConfigurationHandler,
        requestAccessibilityAccess: @escaping () -> Bool
    ) {
        self.settings = settings
        self.configureShortcut = configureShortcut
        self.requestAccessibilityAccess = requestAccessibilityAccess
        shortcutRecorder = ShortcutRecorderButton(shortcut: settings.globalShortcut)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 342),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "OmniGifs Settings"
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.center()
        super.init(window: window)

        window.delegate = self
        configureContent()
        refreshControls()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        refreshControls()
        super.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(sender)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        refreshControls()
    }

    private func configureContent() {
        guard let window else { return }
        let content = NSView()
        window.contentView = content

        let separator = NSBox()
        separator.boxType = .separator
        let footerSeparator = NSBox()
        footerSeparator.boxType = .separator
        shortcutLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        shortcutStatus.textColor = .systemRed
        versionLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        versionLabel.textColor = .secondaryLabelColor
        repositoryButton.bezelStyle = .inline
        repositoryButton.controlSize = .small
        repositoryButton.contentTintColor = .linkColor
        repositoryButton.target = self
        repositoryButton.action = #selector(openRepository)

        let views: [NSView] = [
            autoPasteCheckbox,
            autoPasteDescription,
            accessibilityStatus,
            shiftCheckbox,
            shiftDescription,
            separator,
            shortcutCheckbox,
            shortcutLabel,
            shortcutRecorder,
            shortcutStatus,
            footerSeparator,
            versionLabel,
            repositoryButton,
        ]
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }

        autoPasteCheckbox.target = self
        autoPasteCheckbox.action = #selector(autoPasteChanged)
        shiftCheckbox.target = self
        shiftCheckbox.action = #selector(shiftBehaviorChanged)
        shortcutCheckbox.target = self
        shortcutCheckbox.action = #selector(shortcutEnabledChanged)
        shortcutRecorder.onShortcutChange = { [weak self] shortcut in
            self?.shortcutChanged(to: shortcut)
        }

        NSLayoutConstraint.activate([
            autoPasteCheckbox.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            autoPasteCheckbox.leadingAnchor.constraint(
                equalTo: content.leadingAnchor, constant: 24),
            autoPasteDescription.topAnchor.constraint(
                equalTo: autoPasteCheckbox.bottomAnchor,
                constant: 4
            ),
            autoPasteDescription.leadingAnchor.constraint(
                equalTo: autoPasteCheckbox.leadingAnchor,
                constant: 22
            ),
            autoPasteDescription.trailingAnchor.constraint(
                equalTo: content.trailingAnchor,
                constant: -24
            ),
            accessibilityStatus.topAnchor.constraint(
                equalTo: autoPasteDescription.bottomAnchor,
                constant: 3
            ),
            accessibilityStatus.leadingAnchor.constraint(
                equalTo: autoPasteDescription.leadingAnchor
            ),
            accessibilityStatus.trailingAnchor.constraint(
                equalTo: autoPasteDescription.trailingAnchor
            ),
            shiftCheckbox.topAnchor.constraint(
                equalTo: accessibilityStatus.bottomAnchor,
                constant: 16
            ),
            shiftCheckbox.leadingAnchor.constraint(equalTo: autoPasteCheckbox.leadingAnchor),
            shiftDescription.topAnchor.constraint(
                equalTo: shiftCheckbox.bottomAnchor,
                constant: 4
            ),
            shiftDescription.leadingAnchor.constraint(
                equalTo: shiftCheckbox.leadingAnchor,
                constant: 22
            ),
            shiftDescription.trailingAnchor.constraint(
                equalTo: content.trailingAnchor,
                constant: -24
            ),
            separator.topAnchor.constraint(equalTo: shiftDescription.bottomAnchor, constant: 18),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            shortcutCheckbox.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 18),
            shortcutCheckbox.leadingAnchor.constraint(equalTo: autoPasteCheckbox.leadingAnchor),
            shortcutLabel.centerYAnchor.constraint(equalTo: shortcutRecorder.centerYAnchor),
            shortcutLabel.leadingAnchor.constraint(
                equalTo: shortcutCheckbox.leadingAnchor,
                constant: 24
            ),
            shortcutRecorder.topAnchor.constraint(
                equalTo: shortcutCheckbox.bottomAnchor,
                constant: 12
            ),
            shortcutRecorder.leadingAnchor.constraint(
                equalTo: shortcutLabel.trailingAnchor,
                constant: 8
            ),
            shortcutRecorder.widthAnchor.constraint(greaterThanOrEqualToConstant: 112),
            shortcutStatus.topAnchor.constraint(
                equalTo: shortcutRecorder.bottomAnchor,
                constant: 6
            ),
            shortcutStatus.leadingAnchor.constraint(equalTo: shortcutLabel.leadingAnchor),
            shortcutStatus.trailingAnchor.constraint(
                equalTo: content.trailingAnchor, constant: -24),
            footerSeparator.topAnchor.constraint(
                greaterThanOrEqualTo: shortcutRecorder.bottomAnchor,
                constant: 18
            ),
            footerSeparator.topAnchor.constraint(
                equalTo: shortcutStatus.bottomAnchor,
                constant: 18
            ),
            footerSeparator.leadingAnchor.constraint(
                equalTo: content.leadingAnchor,
                constant: 24
            ),
            footerSeparator.trailingAnchor.constraint(
                equalTo: content.trailingAnchor,
                constant: -24
            ),
            versionLabel.leadingAnchor.constraint(equalTo: footerSeparator.leadingAnchor),
            versionLabel.centerYAnchor.constraint(equalTo: repositoryButton.centerYAnchor),
            repositoryButton.topAnchor.constraint(
                equalTo: footerSeparator.bottomAnchor,
                constant: 14
            ),
            repositoryButton.widthAnchor.constraint(
                equalToConstant: repositoryButton.intrinsicContentSize.width + 8
            ),
            repositoryButton.trailingAnchor.constraint(equalTo: footerSeparator.trailingAnchor),
            repositoryButton.bottomAnchor.constraint(
                lessThanOrEqualTo: content.bottomAnchor,
                constant: -16
            ),
        ])
    }

    private func refreshControls() {
        autoPasteCheckbox.state = settings.pasteGIFURLsAutomatically ? .on : .off
        shiftCheckbox.state = settings.shiftReversesPasteBehavior ? .on : .off
        shortcutCheckbox.state = settings.globalShortcutEnabled ? .on : .off
        shortcutRecorder.shortcut = settings.globalShortcut
        updateAccessibilityStatus()
    }

    @objc private func autoPasteChanged() {
        let enabled = autoPasteCheckbox.state == .on
        settings.pasteGIFURLsAutomatically = enabled
        if enabled { _ = requestAccessibilityAccess() }
        updateAccessibilityStatus()
    }

    @objc private func shiftBehaviorChanged() {
        settings.shiftReversesPasteBehavior = shiftCheckbox.state == .on
    }

    @objc private func shortcutEnabledChanged() {
        shortcutStatus.stringValue = ""
        let enabled = shortcutCheckbox.state == .on
        guard configureShortcut(enabled, settings.globalShortcut) else {
            settings.globalShortcutEnabled = false
            shortcutCheckbox.state = .off
            shortcutStatus.stringValue =
                "That shortcut isn’t available. Choose a different shortcut."
            return
        }
        settings.globalShortcutEnabled = enabled
    }

    private func shortcutChanged(to shortcut: GlobalShortcut) {
        shortcutStatus.stringValue = ""
        let previous = settings.globalShortcut
        guard !settings.globalShortcutEnabled || configureShortcut(true, shortcut) else {
            _ = configureShortcut(true, previous)
            shortcutRecorder.shortcut = previous
            shortcutStatus.stringValue =
                "That shortcut isn’t available. Choose a different shortcut."
            return
        }
        settings.globalShortcut = shortcut
    }

    private func updateAccessibilityStatus() {
        guard settings.pasteGIFURLsAutomatically else {
            accessibilityStatus.stringValue = ""
            return
        }
        accessibilityStatus.stringValue =
            AXIsProcessTrusted()
            ? "OmniGifs has Accessibility access."
            : "Until you allow OmniGifs in Accessibility settings, it copies the URL instead."
    }

    @objc private func openRepository() {
        guard let url = URL(string: "https://github.com/stekc/OmniGifs") else { return }
        NSWorkspace.shared.open(url)
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "Development"
    }

    private static func descriptionLabel(_ value: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: value)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        return label
    }
}
