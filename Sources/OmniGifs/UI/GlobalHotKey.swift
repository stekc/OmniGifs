import AppKit
import Carbon.HIToolbox

@MainActor
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let onPress: () -> Void

    init(onPress: @escaping () -> Void) {
        self.onPress = onPress
    }

    func register() {
        guard hotKeyRef == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                MainActor.assumeIsolated {
                    Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue().onPress()
                }
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef
        )
        let id = EventHotKeyID(signature: OSType(0x4f47_4653), id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_G), UInt32(cmdKey | shiftKey), id, GetApplicationEventTarget(), 0, &hotKeyRef)
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
