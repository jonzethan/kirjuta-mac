import AVFoundation

/// Mikrofon AVAudioEngine-ga -> 16 kHz mono Float32. onSamples kutsutakse jadajärjekorras (mitte helilõimel).
public final class MicCapture {
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "kirjuta.mic", qos: .userInteractive)
    private var converter: AVAudioConverter?

    public init() {}

    public static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// voiceProcessing = Apple'i kajaeemaldus (vaja, kui kõlarid on sees).
    public func start(voiceProcessing: Bool = false, onSamples: @escaping ([Float]) -> Void) throws {
        let input = engine.inputNode
        if voiceProcessing { try input.setVoiceProcessingEnabled(true) }
        let inFmt = input.outputFormat(forBus: 0)
        guard inFmt.sampleRate > 0, inFmt.channelCount > 0 else {
            throw NSError(domain: "Kirjuta", code: 2, userInfo: [NSLocalizedDescriptionKey: "Mikrofoni ei leitud"])
        }
        guard let conv = AVAudioConverter(from: inFmt, to: AudioDecoder.format16k) else {
            throw NSError(domain: "Kirjuta", code: 3, userInfo: [NSLocalizedDescriptionKey: "Teisendus ebaõnnestus"])
        }
        conv.downmix = true
        converter = conv
        let ratio = AudioDecoder.format16k.sampleRate / inFmt.sampleRate
        input.installTap(onBus: 0, bufferSize: 4096, format: inFmt) { [queue] buffer, _ in
            let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: AudioDecoder.format16k, frameCapacity: cap) else { return }
            var given = false
            var err: NSError?
            conv.convert(to: out, error: &err) { _, status in
                if given { status.pointee = .noDataNow; return nil }
                given = true; status.pointee = .haveData; return buffer
            }
            guard err == nil, out.frameLength > 0, let ch = out.floatChannelData else { return }
            let samples = Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
            queue.async { onSamples(samples) }
        }
        engine.prepare()
        try engine.start()
    }

    /// Peatab ja ootab, kuni kõik juba saabunud heli on onSamples-ile edasi antud.
    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        queue.sync {}
    }
}
