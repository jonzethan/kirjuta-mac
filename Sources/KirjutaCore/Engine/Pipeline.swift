import Foundation

/// Üks whisperi töölõim ja üks järjekord kõigile voogudele (mic + süsteem).
/// - Lõplikud tükid on eelisjärjekorras. Kui töö jääb maha, liidetakse sama allika järjestikused tükid (kuni 28 s).
/// - Jooksev tekst (interim): pooleliolev kõne kirjutatakse vahepeal ära, kui lõplikke tükke ei oota.
///   Iga allika kohta hoitakse ainult viimast soovi; vananenud (vahepeal lõigatud) tulemus visatakse ära.
public final class TranscribeWorker: @unchecked Sendable {
    static let maxMergeSamples = 28 * sampleRate

    private let cond = NSCondition()
    private var queue: [Chunk] = []
    private var interims: [Int: Chunk] = [:]
    private var finalizedUpTo: [Int: Int64] = [:]
    private var closed = false
    private var queuedSamples = 0
    private let lang: String
    private let onSegment: (Segment) -> Void
    private let onInterim: (Int, Int64, String) -> Void
    private let onIdle: () -> Void

    /// Tagasikutsed tulevad töölõimel. onInterim(source, startMs, tekst) – tühi tekst = kustuta jooksev tekst.
    public init(lang: String, onSegment: @escaping (Segment) -> Void,
                onInterim: @escaping (Int, Int64, String) -> Void = { _, _, _ in },
                onIdle: @escaping () -> Void) {
        self.lang = lang
        self.onSegment = onSegment
        self.onInterim = onInterim
        self.onIdle = onIdle
        let t = Thread { [self] in run() }
        t.name = "whisper"
        t.qualityOfService = .userInitiated
        t.start()
    }

    /// Mahajäämus: järjekorras ootava (lõpliku) heli pikkus.
    public var backlogMs: Int64 { cond.withLock { Int64(queuedSamples) * 1000 / Int64(sampleRate) } }
    public var isBusyWithFinals: Bool { cond.withLock { !queue.isEmpty } }

    public func submit(_ c: Chunk) {
        cond.withLock {
            queue.append(c)
            queuedSamples += c.samples.count
            finalizedUpTo[c.source] = max(finalizedUpTo[c.source] ?? 0, c.endMs)
            if let i = interims[c.source], i.startMs < c.endMs { interims[c.source] = nil }
            cond.signal()
        }
    }

    public func submitInterim(_ c: Chunk) {
        cond.withLock {
            guard !closed else { return }
            interims[c.source] = c
            cond.signal()
        }
    }

    /// Järjekord lõpeb; töölõim teeb lõplikud tükid ära ja kutsub onIdle.
    public func close() { cond.withLock { closed = true; interims.removeAll(); cond.signal() } }

    private func isStale(_ c: Chunk) -> Bool { c.startMs < (finalizedUpTo[c.source] ?? 0) }

    private func run() {
        let engine = WhisperEngine.shared
        while true {
            cond.lock()
            while queue.isEmpty && interims.isEmpty && !closed { cond.wait() }
            if queue.isEmpty && closed { cond.unlock(); break }

            if !queue.isEmpty {
                var merged = queue.removeFirst()
                while let next = queue.first, next.source == merged.source,
                      merged.samples.count + next.samples.count <= Self.maxMergeSamples {
                    merged.samples += next.samples
                    queue.removeFirst()
                }
                cond.unlock()
                let text = engine.isLoaded
                    ? engine.transcribe(merged.floats(), lang: lang).map(\.text).joined(separator: " ")
                    : ""
                cond.withLock { queuedSamples -= merged.samples.count }
                if text.contains(where: { $0.isLetter || $0.isNumber }) {
                    onSegment(Segment(startMs: merged.startMs, endMs: merged.endMs, text: text, speaker: merged.source))
                }
                continue
            }

            // ainult jooksev tekst ootab
            let (source, chunk) = interims.first!
            interims[source] = nil
            if isStale(chunk) { cond.unlock(); continue }
            cond.unlock()
            let text = engine.isLoaded
                ? engine.transcribe(chunk.floats(), lang: lang, log: false).map(\.text).joined(separator: " ")
                : ""
            let stale = cond.withLock { isStale(chunk) || closed }
            if !stale { onInterim(source, chunk.startMs, text) }
        }
        onIdle()
    }
}

/// Ühe helivoo töötlus: float-heli -> 30 ms kaadrid -> WAV + Chunker -> TranscribeWorker.
/// feed() kutsu alati samast jadajärjekorrast.
public final class StreamPipeline {
    public let source: Int
    private let writer: WavWriter
    private let worker: TranscribeWorker
    private var chunker: Chunker!
    private var pending: [Int16] = []
    public private(set) var totalSamples: Int64 = 0
    private var lastHeader: Int64 = 0
    private var lastInterim: Int64 = 0
    /// Jooksev tekst sees/väljas.
    public var interimEnabled = true
    /// Viimased tasemed 0..1 (iga kaadri kohta), UI jaoks.
    public private(set) var level: Float = 0

    public init(source: Int, wavURL: URL, worker: TranscribeWorker) throws {
        self.source = source
        self.worker = worker
        writer = try WavWriter(url: wavURL)
        chunker = Chunker(source: source) { worker.submit($0) }
    }

    public var elapsedMs: Int64 { totalSamples * 1000 / Int64(sampleRate) }

    public func feed(_ samples: [Float]) {
        pending.reserveCapacity(pending.count + samples.count)
        for s in samples { pending.append(Int16(max(-32768, min(32767, (s * 32767).rounded())))) }
        var off = 0
        var peak: Float = 0
        while pending.count - off >= frameSize {
            let frame = pending[off..<(off + frameSize)]
            writer.write(frame)
            peak = max(peak, chunker.feed(frame))
            off += frameSize
            totalSamples += Int64(frameSize)
        }
        if off > 0 { pending.removeFirst(off); level = peak }
        if totalSamples - lastHeader > Int64(sampleRate * 5) { writer.updateHeader(); lastHeader = totalSamples }
        // jooksev tekst ~1 s tagant, kui lõplikud tükid ei oota
        if interimEnabled, totalSamples - lastInterim >= Int64(sampleRate) {
            lastInterim = totalSamples
            if !worker.isBusyWithFinals, let p = chunker.pending() { worker.submitInterim(p) }
        }
    }

    public func finish() {
        chunker.flush()
        writer.close()
    }
}
