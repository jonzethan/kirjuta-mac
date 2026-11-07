import Foundation

/// Dikteerimine aktiivsesse tekstilahtrisse (üks kõneleja).
/// - Jooksev tekst (sama mis salvestamisel hallina) tuleb kohe, lause lõppedes kirjutatakse lause täpsemalt üle.
/// - Iga lõpetatud lause järel oodatakse võlusõna („saada“, „send it“). Kui see tuleb eraldi lausena, kustutatakse
///   see, saadetakse (Enter) ja oodatakse postSendSec sekundit: uue kõne korral algab uus sõnum, muidu lõpp.
///   Kui tulevad muud sõnad, pannakse eelmise lause lõppu punkt ja jätkatakse.
/// - silenceSec sekundit vaikust -> lõpp ilma saatmata.
///
/// Kõik tagasikutsed tulevad peajärjekorras.
public final class DictationEngine: @unchecked Sendable {
    public enum State: Equatable, Sendable { case listening, writing, awaitingSend, sent, stopped }
    public enum StopReason: Sendable { case user, silence, afterSend }

    public struct Config: Sendable {
        public var magicWords: [String]
        public var silenceSec: Double
        public var postSendSec: Double
        public var lang: String
        public init(magicWords: [String], silenceSec: Double, postSendSec: Double, lang: String) {
            self.magicWords = magicWords; self.silenceSec = silenceSec; self.postSendSec = postSendSec; self.lang = lang
        }
    }

    /// Kogu tekst, mis peaks praegu lahtris olema (selle sõnumi algusest).
    public var onText: (String) -> Void = { _ in }
    /// Võlusõna: lahter peab enne olema tühjendatud võlusõnast (onText tuli juba), siis vajuta Enter.
    public var onSend: () -> Void = {}
    public var onState: (State) -> Void = { _ in }
    public var onLevel: (Float) -> Void = { _ in }
    public var onStop: (StopReason) -> Void = { _ in }
    /// Lõplik lause (salvestamiseks): algus/lõpp ms dikteerimise algusest.
    public var onFinal: (Segment) -> Void = { _ in }

    private let cfg: Config
    private let tracker: LangTracker
    private let work = DispatchQueue(label: "kirjuta.dictation", qos: .userInitiated)
    private let lock = NSLock()
    private var chunker: Chunker!
    private var pendingFinals: [Chunk] = []
    private var interimBusy = false
    private var finalBusy = false

    // tekst (ainult work-järjekorras)
    private var finals: [String] = []
    private var interim = ""

    // aeg (ainult heli-järjekorras)
    private var samplesIn: Int64 = 0
    private var lastSpeechSample: Int64 = 0
    private var lastInterimSample: Int64 = 0
    private var sentAtSample: Int64?
    private var stopped = false

    public init(config: Config) {
        cfg = config
        tracker = LangTracker(mode: config.lang, initial: config.lang == "en" ? "en" : "et")
        // lühem paus kui salvestamisel: lause lõpp (ja võlusõna) tuleb kiiremini
        chunker = Chunker(source: 0, minMs: 800, pauseMs: 700, maxMs: 15000) { [weak self] c in self?.enqueueFinal(c) }
        chunker.minSpeechMs = 200
    }

    /// Mikrofoni heli (16 kHz mono). Kutsu alati samast jadajärjekorrast.
    public func feed(_ samples: [Float]) {
        if lock.withLock({ stopped }) { return }
        var i = 0
        var ints = [Int16](repeating: 0, count: samples.count)
        for s in samples { ints[i] = Int16(max(-32768, min(32767, (s * 32767).rounded()))); i += 1 }
        buffer += ints
        var off = 0
        var peak: Float = 0
        while buffer.count - off >= frameSize {
            peak = max(peak, chunker.feed(buffer[off..<(off + frameSize)]))
            off += frameSize
            samplesIn += Int64(frameSize)
            if chunker.lastFrameSpeech {
                lastSpeechSample = samplesIn
                if sentAtSample != nil { sentAtSample = nil } // räägib edasi: uus sõnum
            }
        }
        if off > 0 { buffer.removeFirst(off) }
        let level = peak
        DispatchQueue.main.async { self.onLevel(level) }

        let sr = Int64(sampleRate)
        if lock.withLock({ let r = sendRequested; sendRequested = false; return r }) { sentAtSample = samplesIn }
        // pärast saatmist: postSendSec vaikust -> lõpp
        if let sent = sentAtSample, samplesIn - sent > Int64(cfg.postSendSec * Double(sr)) {
            finish(.afterSend); return
        }
        if samplesIn - lastSpeechSample > Int64(cfg.silenceSec * Double(sr)) && !hasWork {
            finish(.silence); return
        }
        // jooksev tekst ~0,6 s tagant
        if samplesIn - lastInterimSample >= sr * 6 / 10 {
            lastInterimSample = samplesIn
            if let p = chunker.pending() { enqueueInterim(p) }
        }
    }
    private var buffer: [Int16] = []

    private var hasWork: Bool { lock.withLock { !pendingFinals.isEmpty || finalBusy } }

    /// Kasutaja lõpetas (kiirklahv): viimane lause kirjutatakse veel ära, siis onStop(.user).
    /// Kutsu pärast seda, kui mikrofon on peatatud (feed ei käi enam).
    public func stop() {
        if lock.withLock({ stopped }) { return }
        chunker.flush()
        finish(.user)
    }

    private func finish(_ reason: StopReason) {
        let first: Bool = lock.withLock { if stopped { return false }; stopped = true; return true }
        guard first else { return }
        // ootab, kuni lõplikud tükid on tehtud
        work.async { [self] in
            while lock.withLock({ !pendingFinals.isEmpty }) { processFinal() }
            if !interim.isEmpty { interim = ""; publish() }
            DispatchQueue.main.async { self.onState(.stopped); self.onStop(reason) }
        }
    }

    // MARK: töö

    private func enqueueFinal(_ c: Chunk) {
        lock.withLock { pendingFinals.append(c) }
        work.async { [self] in processFinal() }
    }

    private func enqueueInterim(_ c: Chunk) {
        let skip: Bool = lock.withLock {
            if interimBusy || finalBusy || !pendingFinals.isEmpty { return true }
            interimBusy = true; return false
        }
        if skip { return }
        work.async { [self] in
            defer { lock.withLock { interimBusy = false } }
            if lock.withLock({ !pendingFinals.isEmpty || stopped }) { return }
            let text = WhisperEngine.shared.transcribe(c.floats(), lang: tracker.current, log: false).map(\.text).joined(separator: " ")
            if lock.withLock({ !pendingFinals.isEmpty }) { return } // vahepeal lõigati – vana tulemus
            interim = text
            publish()
            DispatchQueue.main.async { self.onState(.writing) }
        }
    }

    private func processFinal() {
        guard let c: Chunk = lock.withLock({ pendingFinals.isEmpty ? nil : pendingFinals.removeFirst() }) else { return }
        lock.withLock { finalBusy = true }
        defer { lock.withLock { finalBusy = false } }
        let f = c.floats()
        let l = tracker.resolve(f)
        let secs = Double(f.count) / Double(sampleRate)
        // täpsem kui jooksev tekst: suurem aken + varuvariant korduste korral
        var o = WhisperEngine.Options(beam: 1, maxTokens: Int32(secs * 12 + 40))
        let ctx = max(768, Int(secs * 50 + 400)); o.audioCtx = ctx >= 1500 ? 0 : Int32(ctx)
        o.tempInc = 0.2
        let text = WhisperEngine.shared.transcribe(f, lang: l, options: o, log: false).pieces.map(\.text)
            .joined(separator: " ").trimmingCharacters(in: .whitespaces)
        interim = ""
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { publish(); return }

        if isMagic(text) {
            if !finals.isEmpty {
                publish() // võlusõna (jooksev tekst) lahtrist välja
                finals = []
                DispatchQueue.main.async { self.onSend(); self.onState(.sent) }
                markSent()
            } else {
                publish()
            }
            return
        }
        finals.append(text)
        let seg = Segment(startMs: c.startMs, endMs: c.endMs, text: text, speaker: 0)
        publish()
        DispatchQueue.main.async { self.onFinal(seg); self.onState(.awaitingSend) }
    }

    private func markSent() {
        // helijärjekorra muutujad: seatakse järgmises feed-is (lihtsuse mõttes lukuga)
        lock.withLock { sendRequested = true }
    }
    private var sendRequested = false

    /// Kõik lõplikud laused + jooksev tekst. Lause vahel: kui eelmine ei lõppenud märgiga, pane punkt.
    private func publish() {
        var parts = finals
        if !interim.isEmpty { parts.append(interim) }
        var out = ""
        for p in parts {
            if !out.isEmpty {
                if let last = out.last, !".?!…".contains(last) { out += "." }
                out += " "
            }
            out += p
        }
        DispatchQueue.main.async { self.onText(out) }
    }

    func isMagic(_ text: String) -> Bool {
        let n = Self.norm(text)
        return cfg.magicWords.contains { Self.norm($0) == n }
    }

    static func norm(_ s: String) -> String {
        s.lowercased().unicodeScalars.filter { CharacterSet.letters.contains($0) || $0 == " " }
            .map(String.init).joined().split(separator: " ").joined(separator: " ")
    }
}
