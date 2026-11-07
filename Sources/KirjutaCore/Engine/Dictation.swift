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
        let secs = Double(f.count) / Double(sampleRate)
        // lühike tükk (nt ainult „saada“): keeletuvastus on ebakindel -> kasuta senist keelt
        let l = secs < 2 ? tracker.current : tracker.resolve(f)
        var pieces = decode(f, lang: l)
        var text = pieces.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if secs < 2.5, tracker.mode == "auto", !isMagic(text) {
            // võlusõna teises keeles („send it“ eesti keele režiimis jne)
            let other = decode(f, lang: l == "et" ? "en" : "et")
            let t2 = other.map(\.text).joined(separator: " ")
            if isMagic(t2) { pieces = other; text = t2 }
        }
        AppLog.i("Dict", String(format: "lause %.1f s [%@]: %@", secs, l, text))
        interim = ""
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { publish(); return }

        // võlusõna: kogu lause või viimane (pausiga eraldatud) whisperi lõik
        var send = false
        if isMagic(text) {
            send = true; text = ""
        } else if pieces.count >= 2, isMagic(pieces.last!.text) {
            send = true
            text = pieces.dropLast().map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        }
        if !text.isEmpty {
            finals.append(text)
            let seg = Segment(startMs: c.startMs, endMs: c.endMs, text: text, speaker: 0)
            DispatchQueue.main.async { self.onFinal(seg) }
        }
        if send && !finals.isEmpty {
            publish() // lahtris on täpselt sõnum (võlusõna kustutatud)
            finals = []
            AppLog.i("Dict", "saada")
            DispatchQueue.main.async { self.onSend(); self.onState(.sent) }
            markSent()
            return
        }
        publish()
        if !finals.isEmpty { DispatchQueue.main.async { self.onState(.awaitingSend) } }
    }

    private func decode(_ f: [Float], lang: String) -> [Piece] {
        let secs = Double(f.count) / Double(sampleRate)
        // täpsem kui jooksev tekst: suurem aken + varuvariant korduste korral
        var o = WhisperEngine.Options(beam: 1, maxTokens: Int32(secs * 12 + 40))
        let ctx = max(768, Int(secs * 50 + 400)); o.audioCtx = ctx >= 1500 ? 0 : Int32(ctx)
        o.tempInc = 0.2
        return WhisperEngine.shared.transcribe(f, lang: lang, options: o, log: false).pieces
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

    /// Võlusõna, lubatud üks täheviga (5+ tähte): „saada“ ≈ „saata“, „sada“; „send it“ ≈ „sent it“.
    func isMagic(_ text: String) -> Bool {
        let n = Self.norm(text)
        guard !n.isEmpty else { return false }
        return cfg.magicWords.contains { w in
            let m = Self.norm(w)
            return m == n || (m.count >= 5 && Self.distance(m, n) <= 1) || n == m + " " + m
        }
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if abs(x.count - y.count) > 1 { return 2 }
        var d = Array(0...y.count)
        for i in 1...max(1, x.count) where !x.isEmpty {
            var prev = d; d[0] = i
            for j in stride(from: 1, through: y.count, by: 1) {
                d[j] = min(prev[j] + 1, d[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            prev = d
        }
        return d[y.count]
    }

    static func norm(_ s: String) -> String {
        s.lowercased().unicodeScalars.filter { CharacterSet.letters.contains($0) || $0 == " " }
            .map(String.init).joined().split(separator: " ").joined(separator: " ")
    }
}
