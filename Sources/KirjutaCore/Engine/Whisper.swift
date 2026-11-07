import CWhisper
import Foundation

/// Lõik tüki sees: ajad millisekundites tüki algusest.
public struct Piece: Sendable {
    public let t0: Int64
    public let t1: Int64
    public let text: String
}

/// Täpse režiimi ühe akna tulemus: endMs = kus mudel lõpetas (viimase lõigu lõpp enne koristust), 0 = midagi ei tulnud.
public struct Window: Sendable {
    public let pieces: [Piece]
    public let endMs: Int64
}

/// Üks Whisperi kontekst (port Androidi Engine.kt-st). Kutsed on lukuga järjestatud –
/// päriselt kutsub seda ainult üks töölõim (TranscribeWorker).
public final class WhisperEngine: @unchecked Sendable {
    public static let shared = WhisperEngine()
    public static let threads = 4 // M1: 4 jõudlustuuma; kodeerija käib niikuinii Metalil

    private let lock = NSLock()
    private var ctx: UnsafeMutableRawPointer?
    public private(set) var modelPath: String?

    public var isLoaded: Bool { lock.withLock { ctx != nil } }

    @discardableResult
    public func load(path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if ctx != nil && modelPath == path { return true }
        if let c = ctx { kw_free(c); ctx = nil; modelPath = nil }
        kw_quiet_logs(true)
        let t0 = Date()
        ctx = kw_init(path, true)
        if ctx != nil { modelPath = path }
        AppLog.i("Engine", "model \((path as NSString).lastPathComponent) loaded=\(ctx != nil) in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        return ctx != nil
    }

    /// Vabasta kontekst (kohustuslik enne protsessi lõppu, muidu ggml-metal assert exit()-is).
    public func unload() {
        lock.lock(); defer { lock.unlock() }
        if let c = ctx { kw_free(c); ctx = nil; modelPath = nil }
    }

    /// Akna pikkus (audio_ctx) tüki pikkuse järgi: lühike tükk = kiire kodeerija.
    /// 1500 = 30 s. Alla ~400 läheb mudel segadusse, seega vähemalt 640.
    static func audioCtx(forSeconds s: Double) -> Int32 {
        let c = max(640, Int(s * 50 + 250))
        return c >= 1500 ? 0 : Int32(c)
    }

    /// Reaalaja-režiim: lühike aken, greedy.
    public func transcribe(_ samples: [Float], lang: String) -> [Piece] {
        transcribeImpl(samples, lang: lang, accurate: false).pieces
    }

    /// Täpne režiim: ainult üks kodeerija käivitus; kutsuja jätkab järgmist akent kohast Window.endMs.
    public func transcribeWindow(_ samples: [Float], lang: String) -> Window {
        transcribeImpl(samples, lang: lang, accurate: true)
    }

    private func transcribeImpl(_ samples: [Float], lang: String, accurate: Bool) -> Window {
        lock.lock(); defer { lock.unlock() }
        guard let ctx else { return Window(pieces: [], endMs: 0) }
        let seconds = Double(samples.count) / 16000.0
        let actx: Int32
        if accurate {
            if seconds >= 20 { actx = 0 } else {
                let c = max(768, Int(seconds * 50 + 400)); actx = c >= 1500 ? 0 : Int32(c)
            }
        } else {
            actx = Self.audioCtx(forSeconds: seconds)
        }
        let beam: Int32 = accurate ? 2 : 1
        let t0 = Date()
        let raw: String = samples.withUnsafeBufferPointer { buf in
            lang.withCString { l in
                guard let out = kw_transcribe(ctx, buf.baseAddress, Int32(buf.count), Int32(Self.threads), actx, l, beam, accurate) else { return "" }
                defer { kw_free_str(out) }
                return String(decoding: UnsafeRawBufferPointer(start: out, count: strlen(out)), as: UTF8.self)
            }
        }
        var pieces: [Piece] = []
        var seen = Set<String>()
        var cleaned = false
        var endMs: Int64 = 0
        for line in raw.split(separator: "\n") {
            let p = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            if p.count < 3 { continue }
            let rawText = p[2].trimmingCharacters(in: .whitespaces)
            if !rawText.isEmpty { endMs = max(endMs, Int64(p[1]) ?? 0) }
            let text = TextCleaner.clean(rawText)
            if text != rawText { cleaned = true }
            if text.isEmpty || !seen.insert(text.lowercased()).inserted { continue }
            pieces.append(Piece(t0: Int64(p[0]) ?? 0, t1: Int64(p[1]) ?? 0, text: text))
        }
        let ms = Date().timeIntervalSince(t0) * 1000
        AppLog.i("Engine", String(format: "chunk %.1f s ctx=%d beam=%d lang=%@ took %d ms rtf=%.2f%@%@",
                                  seconds, actx, beam, lang, Int(ms), ms / 1000 / max(seconds, 0.001),
                                  accurate ? String(format: " end=%.1f", Double(endMs) / 1000) : "", cleaned ? " cleaned" : ""))
        return Window(pieces: pieces, endMs: endMs)
    }

    public static var systemInfo: String { String(cString: kw_system_info()) }
}
