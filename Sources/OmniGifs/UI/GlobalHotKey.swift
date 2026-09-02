import AppKit
import Carbon.HIToolbox

struct GlobalShortcut: Codable, Equatable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt32
    let key: String

    static let defaultOpenOmniGifs = GlobalShortcut(
        keyCode: UInt32(kVK_ANSI_G),
        modifiers: UInt32(controlKey | optionKey),
        key: "G"
    )

    init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    init?(event: NSEvent) {
        let modifiers = Self.carbonModifiers(from: event.modifierFlags)
        let primaryModifiers = UInt32(cmdKey | optionKey | controlKey)
        guard modifiers & primaryModifiers != 0,
            let key = Self.displayKey(for: event)
        else { return nil }

        self.init(keyCode: UInt32(event.keyCode), modifiers: modifiers, key: key)
    }

    var displayName: String {
        var value = ""
        if modifiers & UInt32(controlKey) != 0 { value += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { value += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { value += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { value += "⌘" }
        return value + key
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        let flags = flags.intersection([.command, .option, .control, .shift])
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    private static func displayKey(for event: NSEvent) -> String? {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Escape: return "⎋"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        default:
            if let functionKey = functionKeyName(for: Int(event.keyCode)) {
                return functionKey
            }
            guard let characters = event.charactersIgnoringModifiers,
                !characters.isEmpty
            else { return nil }
            return characters.uppercased()
        }
    }

    private static func functionKeyName(for keyCode: Int) -> String? {
        let functionKeys = [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8,
            kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16,
            kVK_F17, kVK_F18, kVK_F19, kVK_F20,
        ]
        guard let index = functionKeys.firstIndex(of: keyCode) else { return nil }
        return "F\(index + 1)"
    }
}

@MainActor
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let onPress: () -> Void

    init(onPress: @escaping () -> Void) {
        self.onPress = onPress
    }

    @discardableResult
    func register(_ shortcut: GlobalShortcut) -> Bool {
        unregister()

        var installedHandler: EventHandlerRef?
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                MainActor.assumeIsolated {
                    Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue().onPress()
                }
                return noErr
            },
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &installedHandler
        )
        guard handlerStatus == noErr, let installedHandler else { return false }

        let id = EventHotKeyID(signature: OSType(0x4f47_4653), id: 1)
        var registeredHotKey: EventHotKeyRef?
        let hotKeyStatus = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            id,
            GetApplicationEventTarget(),
            0,
            &registeredHotKey
        )
        guard hotKeyStatus == noErr, let registeredHotKey else {
            RemoveEventHandler(installedHandler)
            return false
        }

        handlerRef = installedHandler
        hotKeyRef = registeredHotKey
        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }
}
