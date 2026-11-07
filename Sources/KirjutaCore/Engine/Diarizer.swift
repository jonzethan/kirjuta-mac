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

    // MARK: hääle-„sõrmejälg“ lause kaupa

    /// Normaliseeritud sõrmejälg iga lause kohta (lühikese lause ümbrust laiendatakse 1 s-ni); nil = ei saanud.
    static func embeddings(_ segs: [Segment], samples: [Int16]) -> [[Float]?] {
        guard let e = kd_emb_create(embModel, 4) else { return segs.map { _ in nil } }
        defer { kd_emb_free(e) }
        let dim = Int(kd_emb_dim(e))
        return segs.map { seg in
            var a = Int(seg.startMs) * 16, b = min(samples.count, Int(seg.endMs) * 16)
            if b - a < 16000 { let pad = (16000 - (b - a)) / 2; a = max(0, a - pad); b = min(samples.count, b + pad) }
            guard b - a >= 8000 else { return nil }
            let f = samples[a..<b].map { Float($0) / 32768 }
            var v = [Float](repeating: 0, count: dim)
            let rc = f.withUnsafeBufferPointer { kd_emb_compute(e, $0.baseAddress, Int32($0.count), &v) }
            guard rc == 0 else { return nil }
            return normalized(v)
        }
    }

    static func normalized(_ v: [Float]) -> [Float] {
        let n = max(1e-6, sqrt(v.reduce(0) { $0 + $1 * $1 })); return v.map { $0 / n }
    }
    static func dot(_ x: [Float], _ y: [Float]) -> Float { zip(x, y).reduce(0) { $0 + $1.0 * $1.1 } }
    static func dur(_ s: Segment) -> Int64 { s.endMs - s.startMs }

    /// Kõnelejate keskmised sõrmejäljed (ainult ≥ 1,5 s lausetest – lühikeste oma on mürane; kaal = pikkus).
    static func centroids(_ segs: [Segment], _ embs: [[Float]?]) -> [Int: [Float]] {
        var cent: [Int: [Float]] = [:]
        for (i, seg) in segs.enumerated() where dur(seg) >= 1500 {
            guard let v = embs[i] else { continue }
            let w = Float(min(10_000, dur(seg))) / 1000
            cent[seg.speaker] = zip(cent[seg.speaker] ?? [Float](repeating: 0, count: v.count), v).map { $0 + $1 * w }
        }
        return cent.mapValues(normalized)
    }

    /// k-keskmised: iga lause lähima keskmise juurde, kuni midagi ei muutu (max 5 korda).
    static func refineByVoice(_ segs: [Segment], _ embs: [[Float]?]) -> [Segment] {
        var out = segs
        for _ in 0..<5 {
            let cent = centroids(out, embs)
            guard cent.count >= 2 else { break }
            var changed = 0
            out = out.enumerated().map { i, seg in
                guard let v = embs[i] else { return seg }
                let best = cent.max { dot(v, $0.value) < dot(v, $1.value) }!.key
                if best != seg.speaker { changed += 1 }
                return Segment(startMs: seg.startMs, endMs: seg.endMs, text: seg.text, speaker: best)
            }
            if changed == 0 { break }
        }
        return renumber(out)
    }

    /// Kõneleja 0 = see, kes räägib esimesena (järgmised 1, 2, …).
    static func renumber(_ segs: [Segment], offset: Int = 0) -> [Segment] {
        var map: [Int: Int] = [:]
        for seg in segs where map[seg.speaker] == nil { map[seg.speaker] = map.count + offset }
        return segs.map { Segment(startMs: $0.startMs, endMs: $0.endMs, text: $0.text, speaker: map[$0.speaker]!) }
    }

    /// Automaatne: pyannote pöörded → lause kaupa kattumine → hääle järgi üle vaadatud.
    /// Pyannote liidab lühikesed vahelesegamised („Mille kallal?“) sageli naabri pöördega; lause kaupa
    /// võrdlus leiab need üles.
    public static func assignByVoice(_ segs: [Segment], _ turns: [Turn], samples: [Int16]) -> [Segment] {
        let out = assign(segs, turns)
        guard Set(out.map(\.speaker)).count >= 2 else { return out }
        let t0 = Date()
        let res = refineByVoice(out, embeddings(out, samples: samples))
        AppLog.i("Diar", "lausete kaupa üle vaadatud \(out.count) lauset, \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        return res
    }

    /// Täpne kõnelejate arv: laused rühmitatakse hääle järgi (keskmise sidemega aglomeratiivne rühmitus
    /// ≥ 1,5 s lausetel, siis k-keskmised). Töötab ka siis, kui pyannote ei leia vahetusi (muusika taustal,
    /// heli kõlaritest). Kiire: ainult sõrmejäljed, ~1–5 s.
    public static func clusterSentences(_ segs: [Segment], samples: [Int16], k: Int) -> [Segment] {
        let t0 = Date()
        guard k >= 2, segs.count >= 2 else { return segs.map { Segment(startMs: $0.startMs, endMs: $0.endMs, text: $0.text, speaker: 0) } }
        let embs = embeddings(segs, samples: samples)
        var minDur: Int64 = 1500
        var idx: [Int] = []
        while true {
            idx = segs.indices.filter { dur(segs[$0]) >= minDur && embs[$0] != nil }
            if idx.count >= k || minDur <= 300 { break }
            minDur /= 2
        }
        guard idx.count >= k else { return segs }
        var clusters = idx.map { [$0] }
        // sarnasuste maatriks
        var sim = [[Float]](repeating: [Float](repeating: 0, count: segs.count), count: segs.count)
        for i in idx { for j in idx where j > i { let d = dot(embs[i]!, embs[j]!); sim[i][j] = d; sim[j][i] = d } }
        while clusters.count > k {
            var best: (Float, Int, Int) = (-.infinity, 0, 1)
            for x in 0..<clusters.count {
                for y in (x + 1)..<clusters.count {
                    var t: Float = 0
                    for i in clusters[x] { for j in clusters[y] { t += sim[i][j] } }
                    let avg = t / Float(clusters[x].count * clusters[y].count)
                    if avg > best.0 { best = (avg, x, y) }
                }
            }
            clusters[best.1] += clusters[best.2]
            clusters.remove(at: best.2)
        }
        var lab = [Int: Int]()
        for (c, members) in clusters.enumerated() { for i in members { lab[i] = c } }
        let cent = Dictionary(uniqueKeysWithValues: clusters.enumerated().map { c, members in
            (c, normalized(members.reduce([Float](repeating: 0, count: embs[members[0]]!.count)) { acc, i in
                zip(acc, embs[i]!).map { $0 + $1 * Float(min(10_000, dur(segs[i]))) / 1000 } }))
        })
        let first = segs.enumerated().map { i, seg in
            let spk = lab[i] ?? embs[i].map { v in cent.max { dot(v, $0.value) < dot(v, $1.value) }!.key } ?? 0
            return Segment(startMs: seg.startMs, endMs: seg.endMs, text: seg.text, speaker: spk)
        }
        let out = refineByVoice(first, embs)
        AppLog.i("Diar", "laused rühmitatud \(k) kõnelejaks: \(segs.count) lauset, \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
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
