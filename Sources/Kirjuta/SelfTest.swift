import Foundation
import KirjutaCore

enum SelfTest {
    static func run(file: String, lang: String, model: String) -> Int32 {
        AppLog.echo = true
        let path = Settings.modelPath(model)
        guard WhisperEngine.shared.load(path: path) else { print("Mudelit ei saanud laadida: \(path)"); return 1 }
        let samples: [Float]
        do { samples = try AudioDecoder.decode(URL(fileURLWithPath: file)) } catch { print("Dekodeerimine: \(error)"); return 1 }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kirjuta-selftest-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let done = DispatchSemaphore(value: 0)
        let t0 = Date()
        let worker = TranscribeWorker(lang: lang, onSegment: { seg in
            Sessions.appendSegment(dir, seg)
            print("[\(formatClock(seg.startMs, forceHours: true))] Mina: \(seg.text)")
        }, onIdle: { done.signal() })
        let pipe = try! StreamPipeline(source: Source.mic, wavURL: Sessions.audio(dir), worker: worker)
        // ~100 ms tükid nagu mikrofonist, aga täiskiirusel
        var off = 0
        while off < samples.count {
            let n = min(1600, samples.count - off)
            pipe.feed(Array(samples[off..<(off + n)]))
            off += n
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
}
