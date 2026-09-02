import AppKit
import Carbon.HIToolbox
import Foundation
import Testing

@testable import OmniGifs

@MainActor
struct AppSettingsTests {
    @Test func safeDefaultsUseControlOptionGWithoutCapturingIt() {
        let (settings, defaults, suiteName) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(!settings.pasteGIFURLsAutomatically)
        #expect(settings.shiftReversesPasteBehavior)
        #expect(!settings.globalShortcutEnabled)
        #expect(settings.globalShortcut == .defaultOpenOmniGifs)
        #expect(settings.globalShortcut.displayName == "⌃⌥G")
    }

    @Test func shiftReversesTheConfiguredPasteBehavior() {
        let (settings, defaults, suiteName) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        settings.pasteGIFURLsAutomatically = false
        #expect(!settings.shouldPasteSelection(shiftPressed: false))
        #expect(settings.shouldPasteSelection(shiftPressed: true))

        settings.pasteGIFURLsAutomatically = true
        #expect(settings.shouldPasteSelection(shiftPressed: false))
        #expect(!settings.shouldPasteSelection(shiftPressed: true))

        settings.shiftReversesPasteBehavior = false
        #expect(settings.shouldPasteSelection(shiftPressed: true))
    }

    @Test func customShortcutPersistsWithModifiersInAppleDisplayOrder() {
        let (settings, defaults, suiteName) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let shortcut = GlobalShortcut(
            keyCode: UInt32(kVK_ANSI_K),
            modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey),
            key: "K"
        )

        settings.globalShortcut = shortcut
        settings.globalShortcutEnabled = true
        let restored = AppSettings(defaults: defaults)

        #expect(restored.globalShortcutEnabled)
        #expect(restored.globalShortcut == shortcut)
        #expect(restored.globalShortcut.displayName == "⌃⌥⇧⌘K")
    }

    private func makeSettings() -> (AppSettings, UserDefaults, String) {
        let suiteName = "OmniGifsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (AppSettings(defaults: defaults), defaults, suiteName)
    }
}
