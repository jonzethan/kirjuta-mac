import Foundation

/// Keele valik: "auto" (eesti/inglise automaatselt), "et" või "en".
/// Auto-režiimis tuvastatakse keel iga tüki/akna kohta (≥ 1 s heli); ebakindla tulemuse korral jääb eelmine keel.
/// Kutsu ühelt lõimelt (whisperi töölõim).
public final class LangTracker: @unchecked Sendable {
    public let mode: String
    private let lock = NSLock()
    private var _current: String
    private var msByLang: [String: Int64] = [:]

    public init(mode: String, initial: String = "et") {
        self.mode = mode
        _current = mode == "auto" ? initial : mode
    }

    /// Viimati kasutatud keel (UI jaoks; lõimekindel).
    public var current: String { lock.withLock { _current } }

    /// Keel, mida räägiti kõige rohkem (sessiooni `lang` faili jaoks).
    public var dominant: String {
        lock.withLock { msByLang.max { $0.value < $1.value }?.key ?? _current }
    }

    /// Vali keel sellele helile (auto-režiimis tuvastab).
    public func resolve(_ samples: [Float]) -> String {
        guard mode == "auto" else { return mode }
        if samples.count >= sampleRate, let p = WhisperEngine.shared.detect(samples) {
            let en = p.en / max(p.et + p.en, 1e-6)
            let prev = current
            let next = en > 0.6 ? "en" : (en < 0.4 ? "et" : prev)
            if next != prev { AppLog.i("Lang", String(format: "%@ -> %@ (en %.2f, et %.2f)", prev, next, p.en, p.et)) }
            lock.withLock { _current = next }
        }
        return current
    }

    public func account(_ lang: String, samples: Int) {
        lock.withLock { msByLang[lang, default: 0] += Int64(samples) * 1000 / Int64(sampleRate) }
    }
}
