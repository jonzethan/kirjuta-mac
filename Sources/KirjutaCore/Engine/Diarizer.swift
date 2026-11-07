import CSherpa
import Foundation

/// Kõnelejate eristamine (port Androidi Diarizer.kt-st): sherpa-onnx pyannote segmenteerimine +
/// wespeaker hääle-„sõrmejälg“ + rühmitamine. Keelest sõltumatu, töötab ainult salvestatud helil (mitte reaalajas).
public enum Diarizer {
    public static let off = 0
    public static let auto = -1
    /// Lävend automaatrežiimis. Android kasutas 0,8; Maci kõnes (üks hääl otse, teine telefoni kõlarist)
    /// jagas 0,8 ühe inimese 3–5 osaks. 0,9 + väikeste rühmade liitmine andis kõigil testfailidel õige arvu.
    static var autoThreshold: Float { Float(ProcessInfo.processInfo.environment["KIRJUTA_THR"] ?? "") ?? 0.9 }
    /// Automaatrežiimis liidetakse rühm, millel on alla selle osa kogu kõnest, ajaliselt lähima kõnelejaga.
    static let minorShare = 0.08

    public struct Turn: Sendable {
        public let startMs: Int64, endMs: Int64, speaker: Int
    }

    static var segModel: String { Settings.diarDir + "/sherpa-onnx-pyannote-segmentation-3-0/model.int8.onnx" }
    static var embModel: String {
        Settings.diarDir + "/" + (ProcessInfo.processInfo.environment["KIRJUTA_EMB"] ?? "wespeaker_en_voxceleb_resnet34_LM.onnx")
    }

    public static var available: Bool {
        FileManager.default.fileExists(atPath: segModel) && FileManager.default.fileExists(atPath: embModel)
    }

    private final class Box { let f: (Double) -> Void; init(_ f: @escaping (Double) -> Void) { self.f = f } }

    /// speakers: auto (-1) või täpne arv. Tagastab kõnelejapöörded, kõneleja 0 = see, kes räägib esimesena.
    public static func run(_ samples: [Int16], speakers: Int, progress: @escaping (Double) -> Void = { _ in }) -> [Turn] {
        guard available else { AppLog.i("Diar", "mudelid puuduvad: \(Settings.diarDir)"); return [] }
        let t0 = Date()
        guard let sd = kd_create(segModel, embModel, Int32(speakers > 0 ? speakers : -1), autoThreshold, 4) else {
            AppLog.i("Diar", "sherpa-onnx ei käivitunud"); return []
        }
        defer { kd_free(sd) }
        let floats = samples.map { Float($0) / 32768 }
        var out: UnsafeMutablePointer<kd_turn>?
        let box = Box(progress)
        let n = withExtendedLifetime(box) {
            floats.withUnsafeBufferPointer { buf in
                kd_process(sd, buf.baseAddress, Int32(buf.count), &out, { done, total, arg in
                    Unmanaged<Box>.fromOpaque(arg!).takeUnretainedValue().f(Double(done) / Double(max(total, 1)))
                    return 0
                }, Unmanaged.passUnretained(box).toOpaque())
            }
        }
        defer { kd_free_turns(out) }
        guard n > 0, let out else { return [] }
        var turns = (0..<Int(n)).map { Turn(startMs: Int64(out[$0].start * 1000), endMs: Int64(out[$0].end * 1000), speaker: Int(out[$0].speaker)) }
        turns.sort { $0.startMs < $1.startMs }
        if speakers <= 0 { turns = mergeMinor(turns) }
        // kõneleja 1 = see, kes räägib esimesena
        var map: [Int: Int] = [:]
        for t in turns where map[t.speaker] == nil { map[t.speaker] = map.count }
        turns = turns.map { Turn(startMs: $0.startMs, endMs: $0.endMs, speaker: map[$0.speaker]!) }
        AppLog.i("Diar", String(format: "%.0f s heli, speakers=%d -> %d pööret, %d kõnelejat, %d ms",
                                Double(samples.count) / 16000, speakers, turns.count, map.count, Int(Date().timeIntervalSince(t0) * 1000)))
        return turns
    }

    /// Väga vähe rääkinud „kõneleja“ on enamasti sama inimene teises akustikas (nt kaugemal mikrofonist).
    static func mergeMinor(_ turns: [Turn]) -> [Turn] {
        var dur: [Int: Int64] = [:]
        for t in turns { dur[t.speaker, default: 0] += t.endMs - t.startMs }
        let total = Double(max(1, dur.values.reduce(0, +)))
        let minor = Set(dur.filter { Double($0.value) / total < minorShare }.keys)
        guard !minor.isEmpty, minor.count < dur.count else { return turns }
        let major = turns.filter { !minor.contains($0.speaker) }
        return turns.map { t in
            guard minor.contains(t.speaker) else { return t }
            let mid = (t.startMs + t.endMs) / 2
            let near = major.min { abs(($0.startMs + $0.endMs) / 2 - mid) < abs(($1.startMs + $1.endMs) / 2 - mid) }!
            return Turn(startMs: t.startMs, endMs: t.endMs, speaker: near.speaker)
        }
    }

    /// Täpsem määramine lause kaupa: iga lause hääle-„sõrmejälg“ võrreldakse kõnelejate keskmise
    /// sõrmejäljega (k-keskmised, algus = pööretega kattumine). Pyannote liidab lühikesed vahelesegamised
    /// („Mille kallal?“) sageli naabri pöördega; lause kaupa võrdlus leiab need üles.
    public static func assignByVoice(_ segs: [Segment], _ turns: [Turn], samples: [Int16]) -> [Segment] {
        var out = assign(segs, turns)
        let speakers = Set(out.map(\.speaker)).sorted()
        guard speakers.count >= 2, ProcessInfo.processInfo.environment["KIRJUTA_VOICE"] != "0",
              let e = kd_emb_create(embModel, 4) else { return out }
        defer { kd_emb_free(e) }
        let dim = Int(kd_emb_dim(e))
        let t0 = Date()
        // sõrmejälg iga lause kohta (vähemalt 1 s heli: lühikese lause ümbrust laiendatakse)
        var embs: [[Float]?] = out.map { seg in
            var a = Int(seg.startMs) * 16, b = min(samples.count, Int(seg.endMs) * 16)
            if b - a < 16000 { let pad = (16000 - (b - a)) / 2; a = max(0, a - pad); b = min(samples.count, b + pad) }
            guard b - a >= 8000 else { return nil }
            let f = samples[a..<b].map { Float($0) / 32768 }
            var v = [Float](repeating: 0, count: dim)
            let rc = f.withUnsafeBufferPointer { kd_emb_compute(e, $0.baseAddress, Int32($0.count), &v) }
            guard rc == 0 else { return nil }
            let n = max(1e-6, sqrt(v.reduce(0) { $0 + $1 * $1 }))
            return v.map { $0 / n }
        }
        func dot(_ x: [Float], _ y: [Float]) -> Float { zip(x, y).reduce(0) { $0 + $1.0 * $1.1 } }
        for _ in 0..<3 {
            // keskmised ainult vähemalt 1,5 s lausetest (lühikeste sõrmejälg on mürane)
            var cent: [Int: [Float]] = [:]
            for (i, seg) in out.enumerated() where seg.endMs - seg.startMs >= 1500 {
                guard let v = embs[i] else { continue }
                let w = Float(min(10_000, seg.endMs - seg.startMs)) / 1000
                cent[seg.speaker] = zip(cent[seg.speaker] ?? [Float](repeating: 0, count: dim), v).map { $0 + $1 * w }
            }
            guard cent.count >= 2 else { break }
            for (k, v) in cent { let n = max(1e-6, sqrt(v.reduce(0) { $0 + $1 * $1 })); cent[k] = v.map { $0 / n } }
            var changed = 0
            out = out.enumerated().map { i, seg in
                guard let v = embs[i] else { return seg }
                let best = cent.max { dot(v, $0.value) < dot(v, $1.value) }!.key
                if best != seg.speaker { changed += 1 }
                return Segment(startMs: seg.startMs, endMs: seg.endMs, text: seg.text, speaker: best)
            }
            if changed == 0 { break }
        }
        embs.removeAll()
        // kõneleja 1 = see, kes räägib esimesena
        var map: [Int: Int] = [:]
        for seg in out where map[seg.speaker] == nil { map[seg.speaker] = speakers[map.count] }
        out = out.map { Segment(startMs: $0.startMs, endMs: $0.endMs, text: $0.text, speaker: map[$0.speaker] ?? $0.speaker) }
        AppLog.i("Diar", "lausete kaupa üle vaadatud \(out.count) lauset, \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        return out
    }

    /// Iga tekstilõik saab kõneleja, kelle hääl selle ajaga kõige rohkem kattub (või lähima).
    public static func assign(_ segs: [Segment], _ turns: [Turn]) -> [Segment] {
        guard !turns.isEmpty else { return segs }
        return segs.map { seg in
            var overlap: [Int: Int64] = [:]
            for t in turns where t.endMs > seg.startMs && t.startMs < seg.endMs {
                overlap[t.speaker, default: 0] += min(t.endMs, seg.endMs) - max(t.startMs, seg.startMs)
            }
            let mid = (seg.startMs + seg.endMs) / 2
            let spk = overlap.max { $0.value < $1.value }?.key
                ?? turns.min { min(abs($0.startMs - mid), abs($0.endMs - mid)) < min(abs($1.startMs - mid), abs($1.endMs - mid)) }!.speaker
            return Segment(startMs: seg.startMs, endMs: seg.endMs, text: seg.text, speaker: spk)
        }
    }
}
