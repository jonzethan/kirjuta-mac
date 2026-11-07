import Foundation
import KirjutaCore

/// Peata testid (ilma aknata):
///   Kirjuta --selftest fail.wav [et|en] [q8_0] [--realtime]   reaalaja-toru (Chunker -> whisper), soovi korral reaalajas tempos + jooksev tekst
///   Kirjuta --import fail [et|en]                             import + täpne ülekirjutus + TÄPSUSTA + eksport
///   lisa `-dataDir /tee` (UserDefaults), et mitte kirjutada ~/Kirjuta alla
enum SelfTest {
    static func loadModel(_ model: String) -> Bool {
        let path = Settings.modelPath(model)
        guard WhisperEngine.shared.load(path: path) else { print("Mudelit ei saanud laadida: \(path)"); return false }
        return true
    }

    static func run(file: String, lang: String, model: String, realtime: Bool) -> Int32 {
        AppLog.echo = true
        guard loadModel(model) else { return 1 }
        let samples: [Float]
        do { samples = try AudioDecoder.decode(URL(fileURLWithPath: file)) } catch { print("Dekodeerimine: \(error)"); return 1 }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kirjuta-selftest-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let done = DispatchSemaphore(value: 0)
        let t0 = Date()
        func stamp() -> String { String(format: "%5.1fs", Date().timeIntervalSince(t0)) }
        let worker = TranscribeWorker(lang: lang, onSegment: { seg in
            Sessions.appendSegment(dir, seg)
            print("\(stamp()) LÕPLIK [\(formatClock(seg.startMs, forceHours: true))–\(formatClock(seg.endMs))] \(seg.text)")
        }, onInterim: { _, start, text in
            print("\(stamp())   jooksev [\(formatClock(start, forceHours: true))] \(text)")
        }, onIdle: { done.signal() })
        let pipe = try! StreamPipeline(source: Source.mic, wavURL: Sessions.audio(dir), worker: worker)
        pipe.interimEnabled = realtime
        var off = 0
        while off < samples.count {
            let n = min(1600, samples.count - off)
            pipe.feed(Array(samples[off..<(off + n)]))
            off += n
            if realtime { usleep(100_000) }
        }
        pipe.finish()
        worker.close()
        done.wait()
        let secs = Double(samples.count) / 16000
        let took = Date().timeIntervalSince(t0)
        WhisperEngine.shared.unload()
        print(String(format: "heli %.1f s, töötlus %.1f s, RTF %.2f · sessioon: %@", secs, took, took / secs, dir.path))
        return 0
    }

    static func importTest(file: String, lang: String) -> Int32 {
        AppLog.echo = true
        guard loadModel(Settings.model) else { return 1 }
        do {
            let dir = try Jobs.importFile(URL(fileURLWithPath: file), lang: lang, created: { print("kaust: \($0.path)") }) { ph, p in
                if ph == .decode || Int(p * 100) % 25 == 0 { print("  \(ph.rawValue) \(Int(p * 100))%") }
            }
            let segs = Sessions.loadSegments(dir)
            print("--- TXT ---\n" + Export.plainText(dir, segs))
            print("--- SRT (algus) ---\n" + Export.subtitles(dir, segs, vtt: false).prefix(300))
            Jobs.refine(dir) { _ in }
            print("--- pärast TÄPSUSTA: \(Sessions.loadSegments(dir).count) lõiku, live-arhiiv olemas: \(FileManager.default.fileExists(atPath: dir.appendingPathComponent("segments.live.tsv").path))")
            print(Export.markdown(dir, Sessions.loadSegments(dir)).prefix(400))
            WhisperEngine.shared.unload()
            return 0
        } catch {
            print("Viga: \(error)"); WhisperEngine.shared.unload(); return 1
        }
    }
}
