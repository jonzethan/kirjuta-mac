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

    /// Kus mudel jookseb. Mõnel Macil/macOS-il (nt 14.5) ei toeta ggml-metal kõiki tehteid ja
    /// whisper_init kutsub abort() – siis kasutatakse aeglasemat, aga töökindlat varianti.
    public enum Backend: String, CaseIterable, Sendable {
        case metal       // GPU + flash attention (kiireim)
        case metalNoFA   // GPU ilma flash attentionita
        case cpu         // ainult protsessor
        public var label: String { self == .metal ? "Metal" : self == .metalNoFA ? "Metal (FA off)" : "CPU" }
    }
    public private(set) var backend: Backend = .metal

    /// Laeb mudeli ja teeb ühe tühja läbimise (Metali soojendus), et ka esimene lause tuleks kiiresti.
    @discardableResult
    public func load(path: String, backend: Backend = .metal) -> Bool {
        lock.lock()
        if ctx != nil && modelPath == path && self.backend == backend { lock.unlock(); return true }
        if let c = ctx { kw_free(c); ctx = nil; modelPath = nil }
        kw_quiet_logs(true)
        let t0 = Date()
        ctx = kw_init(path, backend != .cpu, backend == .metal)
        self.backend = backend
        if ctx != nil { modelPath = path }
        let ok = ctx != nil
        lock.unlock()
        let loadMs = Int(Date().timeIntervalSince(t0) * 1000)
        if ok {
            let t1 = Date()
            _ = transcribeImpl([Float](repeating: 0, count: 16000), lang: "et", accurate: false, log: false)
            AppLog.i("Engine", "model \((path as NSString).lastPathComponent) [\(backend.rawValue)] loaded in \(loadMs) ms, warmup \(Int(Date().timeIntervalSince(t1) * 1000)) ms")
        } else {
            AppLog.i("Engine", "model \((path as NSString).lastPathComponent) FAILED to load")
        }
        return ok
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
    public func transcribe(_ samples: [Float], lang: String, log: Bool = true) -> [Piece] {
        transcribeImpl(samples, lang: lang, accurate: false, log: log).pieces
    }

    /// Täpne režiim: ainult üks kodeerija käivitus; kutsuja jätkab järgmist akent kohast Window.endMs.
    public func transcribeWindow(_ samples: [Float], lang: String) -> Window {
        transcribeImpl(samples, lang: lang, accurate: true)
    }

    /// Dekodeerimise seaded (katsetamiseks ja eri režiimideks).
    public struct Options: Sendable {
        public var audioCtx: Int32? = nil     // nil = heli pikkuse järgi
        public var beam: Int32 = 1
        public var singlePass = false
        public var maxTokens: Int32? = nil    // nil = heli pikkuse järgi (reaalaeg), 0 = piiramata
        public var prompt: String? = nil
        public var noSpeechThold: Float = 0   // 0 = whisper.cpp vaikimisi (0.6)
        public var tempInc: Float = 0         // > 0: halva tulemuse (kordused, madal tõenäosus) korral kõrgema temperatuuriga uuesti
        public init(audioCtx: Int32? = nil, beam: Int32 = 1, singlePass: Bool = false, maxTokens: Int32? = nil,
                    prompt: String? = nil, noSpeechThold: Float = 0) {
            self.audioCtx = audioCtx; self.beam = beam; self.singlePass = singlePass
            self.maxTokens = maxTokens; self.prompt = prompt; self.noSpeechThold = noSpeechThold
        }
    }

    public func transcribe(_ samples: [Float], lang: String, options o: Options, log: Bool = true) -> Window {
        run(samples, lang: lang, o, log: log)
    }

    private func transcribeImpl(_ samples: [Float], lang: String, accurate: Bool, log: Bool = true) -> Window {
        let seconds = Double(samples.count) / 16000.0
        var o = Options()
        if accurate {
            o.beam = 2; o.singlePass = true; o.maxTokens = 0
            if seconds >= 20 { o.audioCtx = 0 } else {
                let c = max(768, Int(seconds * 50 + 400)); o.audioCtx = c >= 1500 ? 0 : Int32(c)
            }
        }
        return run(samples, lang: lang, o, log: log)
    }

    private func run(_ samples: [Float], lang: String, _ o: Options, log: Bool) -> Window {
        lock.lock(); defer { lock.unlock() }
        guard let ctx else { return Window(pieces: [], endMs: 0) }
        let seconds = Double(samples.count) / 16000.0
        let actx = o.audioCtx ?? Self.audioCtx(forSeconds: seconds)
        let beam = o.beam
        let accurate = o.singlePass
        // reaalajas: tokenite eelarve heli pikkuse järgi (kordamise korral ei jää mudel ~20 s kinni)
        let maxTokens: Int32 = o.maxTokens ?? Int32(seconds * 10 + 30)
        let t0 = Date()
        let raw: String = samples.withUnsafeBufferPointer { buf in
            lang.withCString { l in
                (o.prompt ?? "").withCString { pr in
                    guard let out = kw_transcribe(ctx, buf.baseAddress, Int32(buf.count), Int32(Self.threads), actx, l, beam,
                                                  o.singlePass, maxTokens, pr, o.noSpeechThold, o.tempInc) else { return "" }
                    defer { kw_free_str(out) }
                    return String(decoding: UnsafeRawBufferPointer(start: out, count: strlen(out)), as: UTF8.self)
                }
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
        if log { AppLog.i("Engine", String(format: "chunk %.1f s ctx=%d beam=%d lang=%@ took %d ms rtf=%.2f%@%@",
                                  seconds, actx, beam, lang, Int(ms), ms / 1000 / max(seconds, 0.001),
                                  accurate ? String(format: " end=%.1f", Double(endMs) / 1000) : "", cleaned ? " cleaned" : "")) }
        return Window(pieces: pieces, endMs: endMs)
    }

    /// Keeletuvastus eesti/inglise vahel (~0,5 s). nil = ei õnnestunud.
    public func detect(_ samples: [Float]) -> (et: Float, en: Float)? {
        lock.lock(); defer { lock.unlock() }
        guard let ctx else { return nil }
        var pe: Float = 0, pn: Float = 0
        let rc = samples.withUnsafeBufferPointer { kw_detect_et_en(ctx, $0.baseAddress, Int32($0.count), Int32(Self.threads), &pe, &pn) }
        return rc == 0 ? (pe, pn) : nil
    }

    public static var systemInfo: String { String(cString: kw_system_info()) }
}
