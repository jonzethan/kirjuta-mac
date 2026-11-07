import AppKit
import Carbon.HIToolbox

/// Globaalne kiirklahv (Carbon RegisterEventHotKey) – töötab ka siis, kui Kirjuta pole esiplaanil,
/// ja ei vaja Hõlbustuse luba.
@MainActor
final class GlobalHotkey {
    static let shared = GlobalHotkey()
    private var ref: EventHotKeyRef?
    private var handlerInstalled = false
    var action: () -> Void = {}

    func register(keyCode: Int, carbonModifiers: Int) {
        unregister()
        if !handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { GlobalHotkey.shared.action() } }
                return noErr
            }, 1, &spec, nil, nil)
            handlerInstalled = true
        }
        let id = EventHotKeyID(signature: OSType(0x4B49_524A), id: 1) // 'KIRJ'
        let rc = RegisterEventHotKey(UInt32(keyCode), UInt32(carbonModifiers), id, GetApplicationEventTarget(), 0, &ref)
        if rc != noErr { AppLogUI.log("Hotkey: registreerimine ebaõnnestus (\(rc))") }
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }

    /// NSEvent modifikaatorid -> Carbon.
    static func carbon(_ f: NSEvent.ModifierFlags) -> Int {
        var m = 0
        if f.contains(.command) { m |= cmdKey }
        if f.contains(.option) { m |= optionKey }
        if f.contains(.control) { m |= controlKey }
        if f.contains(.shift) { m |= shiftKey }
        return m
    }

    static func label(keyCode: Int, flags: NSEvent.ModifierFlags, chars: String?) -> String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        let names: [Int: String] = [kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋",
                                    kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
                                    kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"]
        return s + (names[keyCode] ?? (chars?.uppercased() ?? "?"))
    }
}

enum AppLogUI {
    static func log(_ s: String) { NSLog("%@", s) }
}
