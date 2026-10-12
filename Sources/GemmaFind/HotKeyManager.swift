import Carbon
import Cocoa

/// Registers the global ⌃Space shortcut via the Carbon hot-key API
/// (works without Accessibility permission).
@MainActor
final class HotKeyManager {
    static let shared = HotKeyManager()

    var onActivate: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    private init() {}

    static let shortcutDisplay = "⌃Space"
    private static let keyCode = UInt32(kVK_Space)          // 49
    private static let carbonModifiers = UInt32(controlKey)

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
        let status = RegisterEventHotKey(Self.keyCode, Self.carbonModifiers, hkID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            NSLog("GemmaFind: failed to register \(Self.shortcutDisplay) (status \(status))")
            return false
        }
        hotKeyRef = ref
        return true
    }

    func unregister() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        if let h = eventHandlerRef { RemoveEventHandler(h); eventHandlerRef = nil }
    }

    /// macOS system shortcuts (System Settings → Keyboard → Keyboard Shortcuts) win over
    /// app hot keys. ⌃Space is "Select the previous input source" by default, so report
    /// any enabled system shortcut bound to the same key combination.
    static func conflictingSystemShortcut() -> String? {
        guard let hotkeys = UserDefaults(suiteName: "com.apple.symbolichotkeys")?
            .dictionary(forKey: "AppleSymbolicHotKeys") else { return nil }
        let names = ["60": "Select the previous input source", "61": "Select next source in Input menu",
                     "64": "Show Spotlight search", "65": "Show Finder search window"]
        let controlMask = 1 << 18   // NSEvent.ModifierFlags.control in the symbolic-hotkeys format
        for (id, raw) in hotkeys {
            guard let entry = raw as? [String: Any],
                  (entry["enabled"] as? Bool) == true || (entry["enabled"] as? Int) == 1,
                  let value = entry["value"] as? [String: Any],
                  let params = value["parameters"] as? [Int], params.count >= 3 else { continue }
            if params[1] == Int(keyCode), params[2] == controlMask {
                return names[id] ?? "a macOS system shortcut"
            }
        }
        return nil
    }

    /// Opens System Settings → Keyboard (Keyboard Shortcuts lives there).
    static func openKeyboardShortcutsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
