import AppKit
import Carbon.HIToolbox

/// System-wide quick-confirm hotkey (Carbon RegisterEventHotKey).
///
/// The old NSEvent local monitor only saw keys while HealthTick itself had
/// keyboard focus — but reminders deliberately never steal focus (issue #24),
/// so the shortcut was dead unless the user clicked the app first. A Carbon
/// hotkey fires regardless of the frontmost app and needs no Accessibility
/// permission. Callers register it ONLY while a confirmable phase is active
/// (alerting / waiting) so the combo — possibly a bare Space — is never
/// swallowed globally outside those moments.
@MainActor
final class QuickConfirmHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var action: (() -> Void)?

    func register(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, action: @escaping () -> Void) {
        unregister()
        self.action = action

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        // The dispatcher target invokes this on the main thread.
        InstallEventHandler(GetEventDispatcherTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let me = Unmanaged<QuickConfirmHotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async {
                me.action?()
            }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)

        var carbonMods: UInt32 = 0
        if modifiers.contains(.command) { carbonMods |= UInt32(cmdKey) }
        if modifiers.contains(.option) { carbonMods |= UInt32(optionKey) }
        if modifiers.contains(.shift) { carbonMods |= UInt32(shiftKey) }
        if modifiers.contains(.control) { carbonMods |= UInt32(controlKey) }

        let hotKeyID = EventHotKeyID(signature: OSType(0x48545F51) /* "HT_Q" */, id: 1)
        RegisterEventHotKey(UInt32(keyCode), carbonMods, hotKeyID, GetEventDispatcherTarget(), 0, &hotKeyRef)
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
        action = nil
    }
}
