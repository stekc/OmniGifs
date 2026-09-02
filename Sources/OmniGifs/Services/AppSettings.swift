import Foundation

@MainActor
final class AppSettings {
    static let shared = AppSettings()

    private enum Key {
        static let pasteGIFURLsAutomatically = "pasteGIFURLsAutomatically"
        static let shiftReversesPasteBehavior = "shiftReversesPasteBehavior"
        static let globalShortcutEnabled = "globalShortcutEnabled"
        static let globalShortcut = "globalShortcut"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var pasteGIFURLsAutomatically: Bool {
        get { defaults.bool(forKey: Key.pasteGIFURLsAutomatically) }
        set { defaults.set(newValue, forKey: Key.pasteGIFURLsAutomatically) }
    }

    var shiftReversesPasteBehavior: Bool {
        get {
            defaults.object(forKey: Key.shiftReversesPasteBehavior) as? Bool ?? true
        }
        set { defaults.set(newValue, forKey: Key.shiftReversesPasteBehavior) }
    }

    var globalShortcutEnabled: Bool {
        get { defaults.bool(forKey: Key.globalShortcutEnabled) }
        set { defaults.set(newValue, forKey: Key.globalShortcutEnabled) }
    }

    var globalShortcut: GlobalShortcut {
        get {
            guard let data = defaults.data(forKey: Key.globalShortcut),
                let shortcut = try? JSONDecoder().decode(GlobalShortcut.self, from: data)
            else { return .defaultOpenOmniGifs }
            return shortcut
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Key.globalShortcut)
        }
    }

    func shouldPasteSelection(shiftPressed: Bool) -> Bool {
        let reversesBehavior = shiftReversesPasteBehavior && shiftPressed
        return pasteGIFURLsAutomatically != reversesBehavior
    }
}
