import Foundation

public let sampleRate = 16000
public let frameSize = 480 // 30 ms

/// Tükk heli transkribeerimiseks. startMs = asukoht sessiooni algusest. source: 0 = Mina (mic), 1 = Nemad (süsteem).
public struct Chunk: Sendable {
    public var startMs: Int64
    public var samples: [Int16]
    public var source: Int
    public var durationMs: Int64 { Int64(samples.count) * 1000 / Int64(sampleRate) }
    public var endMs: Int64 { startMs + durationMs }
    public func floats() -> [Float] { samples.map { Float($0) / 32768 } }
}

/// Lihtne energiapõhine VAD (port Androidi audio/Audio.kt Chunker-ist, sama käitumine):
/// - paus ≥ PAUSE_MS pärast vähemalt MIN_MS heli -> tükk valmis
/// - tükk ≥ MAX_MS -> lõika vaikseima koha pealt viimase 3 s sees
/// - ainult vaikus -> visatakse ära (ei koorma mudelit)
public final class Chunker {
    static let minMs = 1500, pauseMs = 420, maxMs = 12000, prerollMs = 300

    private let emit: (Chunk) -> Void
    private let source: Int
    private let capacity = sampleRate * (maxMs / 1000 + 2)
    private var buf: [Int16]
    private var len = 0
    private var rms: [Float]
    private var isSpeech: [Bool]
    private var frames: Int { len / frameSize }
    private var startSample: Int64 = 0 // buf[0] absoluutne asukoht
    private var noiseFloor = -1.0
    private var silenceRun = 0 // kaadrites
    private var speechFrames = 0

    public init(source: Int, emit: @escaping (Chunk) -> Void) {
        self.source = source
        self.emit = emit
        buf = [Int16](repeating: 0, count: capacity)
        rms = [Float](repeating: 0, count: capacity / frameSize + 1)
        isSpeech = [Bool](repeating: false, count: capacity / frameSize + 1)
    }

    /// Saab alati täpselt frameSize näidist. Tagastab taseme 0..1 visualiseerimiseks.
    @discardableResult
    public func feed(_ frame: ArraySlice<Int16>) -> Float {
        var sum = 0.0
        for s in frame { let d = Double(s); sum += d * d }
        let r = (sum / Double(frameSize)).squareRoot()
        if noiseFloor < 0 { noiseFloor = r }
        noiseFloor = r < noiseFloor ? noiseFloor * 0.9 + r * 0.1 : noiseFloor + (r - noiseFloor) * 0.002
        let speech = r > max(noiseFloor * 1.8, 120.0)

        let f = frames
        buf.replaceSubrange(len..<(len + frameSize), with: frame)
        len += frameSize
        rms[f] = Float(r)
        isSpeech[f] = speech
        if speech { speechFrames += 1; silenceRun = 0 } else { silenceRun += 1 }

        let lenMs = frames * 30
        if speechFrames == 0 && lenMs >= 2000 {
            dropSilence()
        } else if lenMs >= Self.minMs && silenceRun * 30 >= Self.pauseMs && speechFrames * 30 >= 500 {
            let keep = max(silenceRun - 8, 0) // jäta ~240 ms vaikust tüki lõppu
            cut(frames - keep)
        } else if lenMs >= Self.maxMs {
            cut(quietestFrame(frames - 3000 / 30, frames))
        }
        return Float(min(max(r / 6000.0, 0), 1))
    }

    public func flush() {
        if speechFrames * 30 >= 500 { cut(frames) }
        len = 0
    }

    private func quietestFrame(_ from: Int, _ to: Int) -> Int {
        var best = to
        var bestV = Float.greatestFiniteMagnitude
        for i in max(from, 1)..<to where rms[i] < bestV { bestV = rms[i]; best = i }
        return best
    }

    private func cut(_ atFrame: Int) {
        let at = atFrame * frameSize
        emit(Chunk(startMs: startSample * 1000 / Int64(sampleRate), samples: Array(buf[0..<at]), source: source))
        shift(atFrame)
    }

    private func dropSilence() { shift(frames - Self.prerollMs / 30) }

    private func shift(_ nFrames: Int) {
        let n = nFrames * frameSize
        let remainingFrames = frames - nFrames
        if len - n > 0 { buf.replaceSubrange(0..<(len - n), with: buf[n..<len]) }
        if remainingFrames > 0 {
            rms.replaceSubrange(0..<remainingFrames, with: rms[nFrames..<(nFrames + remainingFrames)])
            isSpeech.replaceSubrange(0..<remainingFrames, with: isSpeech[nFrames..<(nFrames + remainingFrames)])
        }
        len -= n
        startSample += Int64(n)
        speechFrames = 0
        silenceRun = 0
        for i in 0..<remainingFrames {
            if isSpeech[i] { speechFrames += 1; silenceRun = 0 } else { silenceRun += 1 }
        }
    }
}
