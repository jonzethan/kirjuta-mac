import AVFoundation

/// Mis tahes helifail (WAV/MP3/M4A/video) -> 16 kHz mono Float32 (AVFoundation).
public enum AudioDecoder {
    public static let format16k = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false)!

    public static func decode(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let inFmt = file.processingFormat
        guard let conv = AVAudioConverter(from: inFmt, to: format16k) else { throw NSError(domain: "Kirjuta", code: 1, userInfo: [NSLocalizedDescriptionKey: "Teisendus ebaõnnestus"]) }
        conv.downmix = true
        var out: [Float] = []
        out.reserveCapacity(Int(Double(file.length) * Double(sampleRate) / inFmt.sampleRate) + 16)
        let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: 32768)!
        let outBuf = AVAudioPCMBuffer(pcmFormat: format16k, frameCapacity: 32768)!
        var eof = false
        while true {
            outBuf.frameLength = 0
            var err: NSError?
            let st = conv.convert(to: outBuf, error: &err) { _, status in
                if eof { status.pointee = .endOfStream; return nil }
                do { try file.read(into: inBuf) } catch { eof = true; status.pointee = .endOfStream; return nil }
                if inBuf.frameLength == 0 { eof = true; status.pointee = .endOfStream; return nil }
                status.pointee = .haveData
                return inBuf
            }
            if let err { throw err }
            if outBuf.frameLength > 0 {
                out.append(contentsOf: UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: Int(outBuf.frameLength)))
            }
            if st == .endOfStream || st == .error { break }
        }
        return out
    }
}
