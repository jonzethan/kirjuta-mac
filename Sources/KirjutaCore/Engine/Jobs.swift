import Foundation

/// Taustatööd (port Androidi FileJobService-ist): helifaili import ja TÄPSUSTA.
/// Täpne režiim: täis 30 s aknad, beam 2, üks kodeerija käivitus akna kohta; järgmine aken algab
/// kohast, kus mudel viimase lõigu lõpetas (pooleli jäänud saba läheb järgmisse aknasse).
public enum Jobs {
    public enum Phase: String, Sendable { case decode = "TEISENDAN", transcribe = "KIRJUTAN" }

    static let window = 30 * sampleRate
    static let minAdvance = 3 * sampleRate

    /// Impordib helifaili uude sessiooni ja kirjutab selle üles. Tagastab sessiooni kausta.
    /// created kutsutakse kohe, kui sessiooni kaust on olemas (vea korral kustuta see).
    public static func importFile(_ file: URL, lang: String, created: (URL) -> Void,
                                  progress: @escaping (Phase, Double) -> Void) throws -> URL {
        let dir = Sessions.create()
        Sessions.setLang(dir, lang)
        Sessions.setTitle(dir, file.lastPathComponent)
        created(dir)
        progress(.decode, -1)
        let t0 = Date()
        let samples: [Float]
        do { samples = try AudioDecoder.decode(file) } catch {
            try? FileManager.default.removeItem(at: dir); throw error
        }
        let w = try WavWriter(url: Sessions.audio(dir))
        let ints = samples.map { Int16(max(-32768, min(32767, ($0 * 32767).rounded()))) }
        w.write(ints[...])
        w.close()
        AppLog.i("Job", "decoded \(file.lastPathComponent) -> \(ints.count / sampleRate) s in \(Int(Date().timeIntervalSince(t0))) s")
        transcribe(dir: dir, sources: [(Sessions.audio(dir), -1)], lang: lang) { progress(.transcribe, $0) }
        AppLog.i("Job", "import done in \(Int(Date().timeIntervalSince(t0))) s")
        return dir
    }

    /// TÄPSUSTA: kogu salvestis uuesti täpses režiimis. Reaalaja-tekst jääb faili segments.live.tsv.
    public static func refine(_ dir: URL, progress: @escaping (Double) -> Void) {
        let t0 = Date()
        let fm = FileManager.default
        var sources: [(URL, Int)]
        if fm.fileExists(atPath: Sessions.system(dir).path) {
            sources = [(Sessions.mic(dir), Source.mic), (Sessions.system(dir), Source.system)]
                .filter { fm.fileExists(atPath: $0.0.path) }
        } else {
            // üks voog: säilita kõneleja, kui kõik lõigud olid sama kõnelejaga (nt Mac mic = 0)
            let spk = Set(Sessions.loadSegments(dir).map(\.speaker))
            sources = [(Sessions.audio(dir), spk.count == 1 ? spk.first! : -1)]
        }
        Sessions.archiveLiveSegments(dir)
        transcribe(dir: dir, sources: sources, lang: Sessions.lang(dir), progress: progress)
        AppLog.i("Job", "refine \(dir.lastPathComponent) done in \(Int(Date().timeIntervalSince(t0))) s")
    }

    static func transcribe(dir: URL, sources: [(URL, Int)], lang: String, progress: @escaping (Double) -> Void) {
        let audios = sources.map { (Sessions.readWav($0.0), $0.1) }
        let grand = max(1, audios.reduce(0) { $0 + $1.0.count })
        var doneBefore = 0
        var all: [Segment] = []
        for (samples, speaker) in audios {
            let total = samples.count
            var pos = 0
            var lastText = ""
            while pos < total {
                let remaining = total - pos
                var len: Int
                if remaining <= window {
                    len = remaining
                } else {
                    // täis aken, lõpp vaikseimast kohast viimase 4 s sees
                    len = quietestCut(samples, pos, window - 4 * sampleRate, window)
                }
                let floats = samples[pos..<(pos + len)].map { Float($0) / 32768 }
                let offsetMs = Int64(pos) * 1000 / Int64(sampleRate)
                let w = WhisperEngine.shared.transcribeWindow(floats, lang: lang)
                for p in w.pieces where p.text.lowercased() != lastText.lowercased() {
                    let seg = Segment(startMs: offsetMs + p.t0, endMs: offsetMs + p.t1, text: p.text, speaker: speaker)
                    all.append(seg)
                    if audios.count == 1 { Sessions.appendSegment(dir, seg) } // jooksvalt nähtav
                    lastText = p.text
                }
                let end = Int(w.endMs) * sampleRate / 1000
                pos += (end >= minAdvance && end < len - sampleRate) ? end : len
                progress(Double(doneBefore + pos) / Double(grand))
            }
            doneBefore += total
        }
        if audios.count > 1 { Sessions.saveSegments(dir, all.sorted { $0.startMs < $1.startMs }) }
    }

    /// 100 ms akende RMS, vaikseima akna keskkoht (pos-ist arvestatuna).
    static func quietestCut(_ s: [Int16], _ pos: Int, _ from: Int, _ to: Int) -> Int {
        let win = sampleRate / 10
        var best = to
        var bestV = Double.greatestFiniteMagnitude
        var i = max(from, win)
        while i + win <= to {
            var sum = 0.0
            for k in (pos + i)..<(pos + i + win) { let d = Double(s[k]); sum += d * d }
            let r = (sum / Double(win)).squareRoot()
            if r < bestV { bestV = r; best = i + win / 2 }
            i += win / 2
        }
        return best
    }
}
