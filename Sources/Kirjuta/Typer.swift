import AppKit
import ApplicationServices

/// Kirjutab teksti aktiivsesse tekstilahtrisse (ükskõik mis äpis) klaviatuurisündmustena.
/// Hoiab meeles, mis on selle sõnumi jooksul juba sisestatud: uue teksti korral kustutab ainult erineva lõpu
/// (tagasilükkeklahviga) ja kirjutab uue lõpu – nii saab jooksvat teksti hiljem täpsemaga asendada.
/// Vajab luba: Süsteemiseaded → Privaatsus ja turvalisus → Hõlbustus → Kirjuta.
final class Typer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "kirjuta.typer", qos: .userInteractive)
    private var typed: [Character] = [] // ainult queue-s

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Näitab macOS-i dialoogi, mis viib Hõlbustuse seadetesse (ainult kui luba pole).
    @discardableResult
    static func requestTrust() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Lahtris peaks olema `text` (selle sõnumi algusest).
    func update(to text: String) {
        queue.async { [self] in
            let want = Array(text)
            var common = 0
            while common < typed.count && common < want.count && typed[common] == want[common] { common += 1 }
            let back = typed.count - common
            if back > 0 { key(51, count: back) } // 51 = Delete (tagasilüke)
            if common < want.count { type(String(want[common...])) }
            typed = want
        }
    }

    /// Enter (sõnum teele) ja uus sõnum algab tühjalt.
    func pressReturn() {
        queue.async { [self] in
            usleep(30_000)
            key(36, count: 1) // 36 = Return
            typed = []
        }
    }

    func reset() { queue.async { [self] in typed = [] } }

    /// Ootab, kuni kõik klahvivajutused on tehtud.
    func flush() { queue.sync {} }

    // MARK: madal tase

    private let source = CGEventSource(stateID: .hidSystemState)

    private func key(_ code: CGKeyCode, count: Int) {
        for _ in 0..<count {
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
                e?.flags = [] // ⌥ võib kiirklahvist veel all olla – ära lase sellel teksti muuta
                e?.post(tap: .cghidEventTap)
            }
            usleep(1500)
        }
    }

    private func type(_ s: String) {
        let utf16 = Array(s.utf16)
        var i = 0
        while i < utf16.count {
            var n = min(16, utf16.count - i)
            // ära lõika surrogaatpaari pooleks
            if n < utf16.count - i, UTF16.isLeadSurrogate(utf16[i + n - 1]) { n -= 1 }
            let chunk = Array(utf16[i..<(i + n)])
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                e?.flags = []
                chunk.withUnsafeBufferPointer { e?.keyboardSetUnicodeString(stringLength: n, unicodeString: $0.baseAddress) }
                e?.post(tap: .cghidEventTap)
            }
            usleep(3000)
            i += n
        }
    }
}
