import AppKit
import ApplicationServices
import OSLog

@MainActor
final class StatusBarController: NSObject, GIFPickerViewControllerDelegate, NSPopoverDelegate {
    private static let logger = Logger(subsystem: "win.stkc.omnigifs", category: "Lifecycle")
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var picker: GIFPickerViewController
    private let discordSession: DiscordSessionCoordinator
    private let settings = AppSettings.shared
    private var pickerIsPresented = false
    private var previousApp: NSRunningApplication?
    private lazy var globalHotKey = GlobalHotKey { [weak self] in
        self?.toggleFromHotKey()
    }
    private lazy var settingsWindowController = SettingsWindowController(
        settings: settings,
        configureShortcut: { [weak self] enabled, shortcut in
            self?.configureGlobalShortcut(enabled: enabled, shortcut: shortcut) ?? false
        },
        requestAccessibilityAccess: { [weak self] in
            self?.requestAccessibilityTrust() ?? false
        }
    )
    private lazy var discordMenuItem = NSMenuItem(
        title: "Log In",
        action: #selector(logInToDiscord),
        keyEquivalent: ""
    )
    private lazy var settingsMenuItem: NSMenuItem = {
        let item = NSMenuItem(
            title: "Settings…",
            action: #selector(showSettings),
            keyEquivalent: ","
        )
        item.target = self
        return item
    }()
    private lazy var contextMenu: NSMenu = {
        let menu = NSMenu()
        discordMenuItem.target = self
        menu.addItem(discordMenuItem)
        menu.addItem(.separator())
        menu.addItem(settingsMenuItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: "Quit OmniGifs",
            action: #selector(quitApplication),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }()

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        discordSession = DiscordSessionCoordinator.shared
        picker = GIFPickerViewController(
            library: .shared,
            session: discordSession,
            search: .shared
        )
        super.init()

        picker.delegate = self
        picker.preferredContentSize = NSSize(width: 526, height: 650)
        configurePopover()
        configureMainMenu()
        picker.startInitialRefresh()
        Task(priority: .utility) {
            await SearchCoordinator.shared.prepareForLaunch()
        }

        if let button = statusItem.button {
            if let iconURL = AppResources.bundle.url(
                forResource: "omnigifs-icon",
                withExtension: "svg"
            ), let icon = NSImage(contentsOf: iconURL) {
                icon.size = NSSize(width: 18, height: 18)
                icon.isTemplate = true
                icon.accessibilityDescription = "Open OmniGifs"
                button.image = icon
            }
            button.target = self
            button.action = #selector(statusItemPressed)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem.autosaveName = "win.stkc.omnigifs.status-item"

        if settings.globalShortcutEnabled,
            !globalHotKey.register(settings.globalShortcut)
        {
            settings.globalShortcutEnabled = false
        }
    }

    @objc private func statusItemPressed() {
        if NSApp.currentEvent?.type == .rightMouseUp,
            let event = NSApp.currentEvent,
            let button = statusItem.button
        {
            updateDiscordMenuItem()
            NSMenu.popUpContextMenu(contextMenu, with: event, for: button)
            return
        }

        if popover.isShown {
            dismissPickerIfNeeded()
            popover.performClose(nil)
            return
        }

        presentPopover()
    }

    @objc private func quitApplication() {
        NSApp.terminate(nil)
    }

    @objc private func showSettings() {
        if popover.isShown {
            dismissPickerIfNeeded()
            popover.performClose(nil)
        }
        settingsWindowController.showWindow(nil)
    }

    private func configureGlobalShortcut(
        enabled: Bool,
        shortcut: GlobalShortcut
    ) -> Bool {
        guard enabled else {
            globalHotKey.unregister()
            return true
        }
        return globalHotKey.register(shortcut)
    }

    private func toggleFromHotKey() {
        if popover.isShown {
            dismissPickerIfNeeded()
            popover.performClose(nil)
            return
        }
        presentPopover()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func requestAccessibilityTrust() -> Bool {
        guard !AXIsProcessTrusted() else { return true }
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        return AXIsProcessTrusted()
    }

    @objc private func logInToDiscord() {
        discordSession.showLoginWindow()
    }

    @objc private func logOutOfDiscord() {
        Task {
            await discordSession.logOut()
            do {
                try GIFLibrary.shared.clearLocalData()
                try await SearchCoordinator.shared.clearLocalData()
                try await ThumbnailPipeline.shared.clearDiskCache()
                try await WebPVideoTranscoder.shared.clearCache()
                GIFVisualCache.shared.removeAnimations()
                GIFVisualCache.shared.removeThumbnails()
            } catch {
                Self.logger.error(
                    "Unable to clear local data: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func updateDiscordMenuItem() {
        if discordSession.state == .connected {
            discordMenuItem.title = "Log Out"
            discordMenuItem.action = #selector(logOutOfDiscord)
        } else {
            discordMenuItem.title = "Log In"
            discordMenuItem.action = #selector(logInToDiscord)
        }
    }

    private func presentPopover() {
        guard let button = statusItem.button, !popover.isShown else { return }
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = front
        } else {
            previousApp = nil
        }
        if popover.contentViewController == nil {
            popover.contentViewController = picker
            popover.contentSize = picker.preferredContentSize
        }
        picker.prepareForPresentation()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        pickerIsPresented = true
        picker.didPresent()
    }

    private func configurePopover() {
        popover.behavior = .transient
        // Live GIF and AVPlayer layers can flash while an NSPopover scales/fades.
        // An instant presentation also makes repeated menu-bar access feel faster.
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = picker
        popover.contentSize = picker.preferredContentSize
    }

    func popoverWillClose(_ notification: Notification) {
        dismissPickerIfNeeded()
    }

    func popoverDidClose(_ notification: Notification) {
        dismissPickerIfNeeded()
    }

    private func dismissPickerIfNeeded() {
        guard pickerIsPresented else { return }
        pickerIsPresented = false
        picker.didDismiss()
    }

    func gifPicker(_ picker: GIFPickerViewController, didChoose favorite: GIFFavorite) {
        dismissPickerIfNeeded()
        popover.performClose(nil)
        let pasteRequested = settings.shouldPasteSelection(
            shiftPressed: NSEvent.modifierFlags.contains(.shift)
        )
        guard pasteRequested else {
            GIFSelectionWriter.copySourceURL(of: favorite)
            return
        }
        guard requestAccessibilityTrust(), let target = previousApp else {
            GIFSelectionWriter.copySourceURL(of: favorite)
            return
        }
        previousApp = nil
        Task { [weak self] in
            await self?.paste(favorite, into: target)
        }
    }

    private func paste(_ favorite: GIFFavorite, into target: NSRunningApplication) async {
        guard !target.isTerminated, target.activate() else {
            GIFSelectionWriter.copySourceURL(of: favorite)
            return
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while NSWorkspace.shared.frontmostApplication?.processIdentifier
            != target.processIdentifier
        {
            guard clock.now < deadline, !target.isTerminated else {
                GIFSelectionWriter.copySourceURL(of: favorite)
                return
            }
            try? await Task.sleep(for: .milliseconds(25))
        }

        guard
            NSWorkspace.shared.frontmostApplication?.processIdentifier
                == target.processIdentifier,
            GIFSelectionWriter.pasteSourceURL(of: favorite)
        else {
            GIFSelectionWriter.copySourceURL(of: favorite)
            return
        }
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu()

        let aboutItem = NSMenuItem(
            title: "About OmniGifs",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = NSApp
        applicationMenu.addItem(aboutItem)
        applicationMenu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(showSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        applicationMenu.addItem(settingsItem)
        applicationMenu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit OmniGifs",
            action: #selector(quitApplication),
            keyEquivalent: "q"
        )
        quitItem.target = self
        applicationMenu.addItem(quitItem)

        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)
        NSApp.mainMenu = mainMenu
    }
}
