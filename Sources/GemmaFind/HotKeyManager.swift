import Carbon
import Cocoa

/// Registers the global ⌃⇧F shortcut via the Carbon hot-key API
/// (works without Accessibility permission).
@MainActor
final class HotKeyManager {
    static let shared = HotKeyManager()

    var onActivate: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    private init() {}

    static let shortcutDisplay = "⌃⇧F"

    /// Returns false if the shortcut could not be registered (e.g. another app owns it).
    @discardableResult
    func register() -> Bool {
        unregister()
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, eventRef, _ -> OSStatus in
            guard let eventRef else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(eventRef, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            if status == noErr, hotKeyID.id == 1 {
                DispatchQueue.main.async { HotKeyManager.shared.onActivate?() }
            }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType, nil, &eventHandlerRef)

        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x474D_4644), id: 1) // 'GMFD'
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_F), UInt32(controlKey | shiftKey), hkID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            NSLog("GemmaFind: failed to register ⌃⇧F (status \(status))")
            return false
        }
        hotKeyRef = ref
        return true
    }

    func unregister() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        if let h = eventHandlerRef { RemoveEventHandler(h); eventHandlerRef = nil }
    }
}
