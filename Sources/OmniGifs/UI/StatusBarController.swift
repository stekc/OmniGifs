import AppKit
import OSLog

@MainActor
final class StatusBarController: NSObject, GIFPickerViewControllerDelegate, NSPopoverDelegate {
    private static let logger = Logger(subsystem: "win.stkc.omnigifs", category: "Lifecycle")
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var picker: GIFPickerViewController
    private let discordSession: DiscordSessionCoordinator
    private var pickerIsPresented = false
    private lazy var discordMenuItem = NSMenuItem(
        title: "Log In to Discord",
        action: #selector(logInToDiscord),
        keyEquivalent: ""
    )
    private lazy var contextMenu: NSMenu = {
        let menu = NSMenu()
        discordMenuItem.target = self
        menu.addItem(discordMenuItem)
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
        picker.startInitialRefresh()

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
            discordMenuItem.title = "Log Out of Discord"
            discordMenuItem.action = #selector(logOutOfDiscord)
        } else {
            discordMenuItem.title = "Log In to Discord"
            discordMenuItem.action = #selector(logInToDiscord)
        }
    }

    private func presentPopover() {
        guard let button = statusItem.button, !popover.isShown else { return }
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
        GIFSelectionWriter.copySourceURL(of: favorite)
        dismissPickerIfNeeded()
        popover.performClose(nil)
    }
}
