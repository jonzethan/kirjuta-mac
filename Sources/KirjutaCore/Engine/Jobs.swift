import Foundation

/// Taustatööd (port Androidi FileJobService-ist): helifaili import ja TÄPSUSTA.
/// Täpne režiim: kõnelõigud (VAD) rühmitatakse kuni 15 s akendeks, beam 2, üks kodeerija käivitus akna kohta.
/// (Pimesi 30 s aknad jätsid katsetes kõnet vahele: vaikusega algav aken visati „vaikuseks“ ja
/// aken võis alata keset sõna – vt TULEMUSED-MAC.md.)
public enum Jobs {
    public enum Phase: String, Sendable { case decode = "TEISENDAN", transcribe = "KIRJUTAN" }

    /// Impordib helifaili uude sessiooni ja kirjutab selle üles. Tagastab sessiooni kausta.
    /// created kutsutakse kohe, kui sessiooni kaust on olemas (vea korral kustuta see).
    /// lang: "auto" | "et" | "en".
    public static func importFile(_ file: URL, lang: String, created: (URL) -> Void,
                                  progress: @escaping (Phase, Double) -> Void) throws -> URL {
        let dir = Sessions.create()
        Sessions.setLang(dir, lang == "en" ? "en" : "et")
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
        let tracker = LangTracker(mode: lang)
        transcribe(dir: dir, sources: [(Sessions.audio(dir), -1)], lang: tracker) { progress(.transcribe, $0) }
        Sessions.setLang(dir, tracker.dominant)
        AppLog.i("Job", "import done in \(Int(Date().timeIntervalSince(t0))) s")
        return dir
    }

    /// TÄPSUSTA: kogu salvestis uuesti täpses režiimis. Reaalaja-tekst jääb faili segments.live.tsv.
    /// lang: "auto" | "et" | "en".
    /// cancelled() = true katkestab; siis taastatakse reaalaja-tekst. Tagastab, kas jõudis lõpuni.
    @discardableResult
    public static func refine(_ dir: URL, lang: String, cancelled: () -> Bool = { false },
                              progress: @escaping (Double) -> Void) -> Bool {
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
        let tracker = LangTracker(mode: lang, initial: Sessions.lang(dir))
        guard transcribe(dir: dir, sources: sources, lang: tracker, cancelled: cancelled, progress: progress) else {
            Sessions.restoreLiveSegments(dir)
            AppLog.i("Job", "refine \(dir.lastPathComponent) cancelled")
            return false
        }
        Sessions.setLang(dir, tracker.dominant)
        AppLog.i("Job", "refine \(dir.lastPathComponent) done in \(Int(Date().timeIntervalSince(t0))) s")
        return true
    }

    /// Kirjutab allikad täpses režiimis sessiooni. false = katkestati.
    @discardableResult
    static func transcribe(dir: URL, sources: [(URL, Int)], lang: LangTracker, cancelled: () -> Bool = { false },
                           progress: @escaping (Double) -> Void) -> Bool {
        let audios = sources.map { (Sessions.readWav($0.0), $0.1) }
        let grand = Double(max(1, audios.reduce(0) { $0 + $1.0.count }))
        var doneBefore = 0
        var all: [Segment] = []
        for (samples, speaker) in audios {
            let segs = accurate(samples, speaker: speaker, lang: lang, cancelled: cancelled,
                                progress: { progress((Double(doneBefore) + $0 * Double(samples.count)) / grand) },
                                emit: { if audios.count == 1 { Sessions.appendSegment(dir, $0) } }) // jooksvalt nähtav
            if cancelled() { return false }
            all += segs
            doneBefore += samples.count
        }
        if audios.count > 1 { Sessions.saveSegments(dir, all.sorted { $0.startMs < $1.startMs }) }
        return true
    }

    /// Kõnelõigud (VAD) heli sees: (algus, lõpp) näidistes.
    static func speechRegions(_ s: [Int16]) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        let ch = Chunker(source: 0) { c in
            let a = Int(c.startMs) * sampleRate / 1000
            out.append((a, a + c.samples.count))
        }
        var i = 0
        while i + frameSize <= s.count { ch.feed(s[i..<(i + frameSize)]); i += frameSize }
        ch.flush()
        return out
    }

    /// Täpne ülekirjutus VAD-rühmade kaupa: kõnelõigud liidetakse kuni groupSec pikkusteks rühmadeks
    /// (pikem kui 3 s vaikus alustab uut rühma), iga rühm = üks kodeerija käivitus, beam.
    /// Kui mudel jättis rühma lõpu kirjutamata, tehakse ülejäänud lõigud uue rühmana.
    /// Kui tulemus on kahtlaselt hõre (mudel hüppas kõnest üle), kirjutatakse lõigud ükshaaval.
    public static func accurate(_ s: [Int16], speaker: Int, lang: LangTracker, groupSec: Double = 15, beam: Int32 = 2,
                                cancelled: () -> Bool = { false }, progress: (Double) -> Void = { _ in }, emit: (Segment) -> Void = { _ in }) -> [Segment] {
        let regions = speechRegions(s)
        let maxLen = Int(groupSec * Double(sampleRate))
        let maxGap = 3 * sampleRate
        var out: [Segment] = []
        var lastText = ""
        func ms(_ n: Int) -> Int64 { Int64(n) * 1000 / Int64(sampleRate) }
        func add(_ seg: Segment) {
            guard seg.text.lowercased() != lastText.lowercased() else { return }
            out.append(seg); emit(seg); lastText = seg.text
        }
        func decode(_ a: Int, _ b: Int) -> (Window, String) {
            let f = s[a..<b].map { Float($0) / 32768 }
            let secs = Double(b - a) / Double(sampleRate)
            let l = lang.resolve(f)
            lang.account(l, samples: b - a)
            var o = WhisperEngine.Options(beam: beam, singlePass: true, maxTokens: Int32(secs * 12 + 40), noSpeechThold: 2)
            if secs >= 20 { o.audioCtx = 0 } else { let c = max(768, Int(secs * 50 + 400)); o.audioCtx = c >= 1500 ? 0 : Int32(c) }
            return (WhisperEngine.shared.transcribe(f, lang: l, options: o), l)
        }
        // lõigud ükshaaval (varuvariant)
        func each(_ rs: ArraySlice<(Int, Int)>) {
            for r in rs {
                let (w, _) = decode(r.0, r.1)
                for p in w.pieces { add(Segment(startMs: ms(r.0) + p.t0, endMs: ms(r.0) + p.t1, text: p.text, speaker: speaker)) }
            }
        }
        var i = 0
        while i < regions.count && !cancelled() {
            // rühm: regions[i..<j]
            var j = i + 1
            while j < regions.count, regions[j].1 - regions[i].0 <= maxLen, regions[j].0 - regions[j - 1].1 <= maxGap { j += 1 }
            let a = regions[i].0, b = regions[j - 1].1
            let (w, _) = decode(a, b)
            let speechSec = regions[i..<j].reduce(0.0) { $0 + Double($1.1 - $1.0) } / Double(sampleRate)
            let chars = w.pieces.reduce(0) { $0 + $1.text.count }
            // üle hüpatud kõne: üks pikk lõik vähese tekstiga või kogu rühm liiga hõre
            let skipped = w.pieces.contains { Double($0.t1 - $0.t0) > 8000 && Double($0.text.count) / (Double($0.t1 - $0.t0) / 1000) < 3 }
            if j - i > 1 && (skipped || Double(chars) < speechSec * 3) {
                AppLog.i("Job", String(format: "rühm %.1f–%.1f s hõre (%d märki / %.1f s kõnet) -> lõigud ükshaaval",
                                       Double(a) / 16000, Double(b) / 16000, chars, speechSec))
                each(regions[i..<j])
                i = j
            } else {
                for p in w.pieces { add(Segment(startMs: ms(a) + p.t0, endMs: ms(a) + p.t1, text: p.text, speaker: speaker)) }
                // mudel lõpetas varem: järgmine rühm algab esimesest lõigust, mis algab pärast viimast teksti
                let end = a + Int(w.endMs) * sampleRate / 1000
                var k = i + 1
                while k < j, regions[k].0 < end - sampleRate / 4 { k += 1 }
                if w.endMs > 0 && k < j && b - end > 2 * sampleRate { i = k } else { i = j }
            }
            progress(Double(regions[min(i, regions.count - 1)].0) / Double(max(1, s.count)))
        }
        return out
    }
}
