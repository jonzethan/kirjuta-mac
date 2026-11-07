import Foundation
import KirjutaCore

/// Katsete tööriist: sama heli eri seadetega, tulemus stdout-i (t0 \t t1 \t tekst), statistika stderr-i.
///   Kirjuta --bench fail.wav lang rt  pauseMs minMs maxMs ctx beam prompt(0|1) minRms
///   Kirjuta --bench fail.wav lang win                       (praegune TÄPSUSTA)
///   Kirjuta --bench fail.wav lang vad groupSec beam [model]  (VAD-tükid rühmadeks, iga rühm üks aken)
enum Bench {
    static func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

    static func run(_ a: [String]) -> Int32 {
        guard a.count >= 3 else { err("vt Bench.swift"); return 1 }
        let file = a[0], lang = a[1], mode = a[2]
        let p = Array(a.dropFirst(3))
        func int(_ i: Int, _ d: Int) -> Int { i < p.count ? Int(p[i]) ?? d : d }
        let model = (mode == "vad" && p.count > 2) ? p[2] : Settings.model
        guard WhisperEngine.shared.load(path: Settings.modelPath(model)) else { err("mudel"); return 1 }
        defer { WhisperEngine.shared.unload() }
        let floats = try! AudioDecoder.decode(URL(fileURLWithPath: file))
        let ints = floats.map { Int16(max(-32768, min(32767, ($0 * 32767).rounded()))) }
        let tracker = LangTracker(mode: lang)
        let t0 = Date()
        var out: [(Int64, Int64, String)] = []

        switch mode {
        case "rt":
            let pause = int(0, 420), minMs = int(1, 1500), maxMs = int(2, 12000), ctx = int(3, -1), beam = int(4, 1), prompt = int(5, 0), minRms = int(6, 120)
            var chunks: [Chunk] = []
            let ch = Chunker(source: 0, minMs: minMs, pauseMs: pause, maxMs: maxMs, minRms: Double(minRms)) { chunks.append($0) }
            var i = 0
            while i + frameSize <= ints.count { ch.feed(ints[i..<(i + frameSize)]); i += frameSize }
            ch.flush()
            var prev = ""
            for c in chunks {
                let f = c.floats()
                let l = tracker.resolve(f)
                var o = WhisperEngine.Options(beam: Int32(beam))
                if ctx >= 0 { o.audioCtx = Int32(ctx) }
                if prompt == 1 && !prev.isEmpty { o.prompt = String(prev.suffix(200)) }
                let text = WhisperEngine.shared.transcribe(f, lang: l, options: o, log: false).pieces.map(\.text).joined(separator: " ")
                if text.contains(where: \.isLetter) { out.append((c.startMs, c.endMs, text)); prev = text }
            }
            err("chunks \(chunks.count), avg \(chunks.isEmpty ? 0 : chunks.map(\.durationMs).reduce(0, +) / Int64(chunks.count)) ms")
        case "win":
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kirjuta-bench-\(getpid())")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let w = try! WavWriter(url: Sessions.audio(dir)); w.write(ints[...]); w.close()
            Jobs.refine(dir, lang: lang) { _ in }
            out = Sessions.loadSegments(dir).map { ($0.startMs, $0.endMs, $0.text) }
            try? FileManager.default.removeItem(at: dir)
        case "vad":
            let segs = Jobs.accurate(ints, speaker: 0, lang: tracker, groupSec: Double(int(0, 28)), beam: Int32(int(1, 2)))
            out = segs.map { ($0.startMs, $0.endMs, $0.text) }
        default:
            err("tundmatu režiim"); return 1
        }
        for o in out { print("\(o.0)\t\(o.1)\t\(o.2)") }
        let took = Date().timeIntervalSince(t0)
        err(String(format: "%@ %@: %d lõiku, %.1f s, RTF %.3f", mode, p.joined(separator: " "), out.count, took, took / (Double(ints.count) / 16000)))
        return 0
    }
}
