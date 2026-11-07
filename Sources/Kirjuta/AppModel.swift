import AppKit
import Foundation
import KirjutaCore

@MainActor
final class AppModel: ObservableObject {
    enum ModelState: Equatable { case loading, ready, failed(String) }

    @Published var recording = false
    @Published var finishing = false
    @Published var segments: [Segment] = []
    @Published var speakerNames: [Int: String] = [:]
    @Published var elapsedMs: Int64 = 0
    @Published var micLevels: [Float] = Array(repeating: 0, count: 6)
    @Published var backlogMs: Int64 = 0
    @Published var error: String?
    @Published var modelState: ModelState = .loading
    @Published var sessions: [URL] = []
    @Published var selected: URL? { didSet { if !recording { loadSelected() } } }
    @Published var lang: String = Settings.lang { didSet { Settings.lang = lang } }
    @Published var model: String = Settings.model { didSet { if model != oldValue { Settings.model = model; loadModel() } } }

    static let models = ["q8_0", "f16", "q5_0"]

    private var mic: MicCapture?
    private var pipe: StreamPipeline?
    private var worker: TranscribeWorker?
    private var sessionDir: URL?

    init() {
        refreshSessions()
        loadModel()
    }

    func loadModel() {
        modelState = .loading
        let path = Settings.modelPath(model)
        Task.detached {
            let ok = WhisperEngine.shared.load(path: path)
            await MainActor.run { self.modelState = ok ? .ready : .failed("Mudelit ei leitud: \(path)") }
        }
    }

    func refreshSessions() { sessions = Sessions.list() }

    private func loadSelected() {
        guard let dir = selected else { segments = []; return }
        segments = Sessions.loadSegments(dir)
        speakerNames = Sessions.speakerNames(dir)
    }

    func speakerLabel(_ s: Int) -> String? {
        guard s >= 0 else { return nil }
        if let n = speakerNames[s] { return n }
        return Sessions.speakerName([:], s)
    }

    func toggle() {
        if recording { stop() } else if !finishing { Task { await start() } }
    }

    func start() async {
        error = nil
        guard modelState == .ready else { error = "Mudel pole veel laaditud"; return }
        guard await MicCapture.requestPermission() else {
            error = "Mikrofoni luba puudub: Süsteemiseaded → Privaatsus ja turvalisus → Mikrofon → lülita „Kirjuta“ sisse"
            return
        }
        let dir = Sessions.create()
        let lang = self.lang
        Sessions.setLang(dir, lang)
        Sessions.setSpeakerNames(dir, [Source.mic: "Mina"])
        let worker = TranscribeWorker(lang: lang, onSegment: { [weak self] seg in
            Sessions.appendSegment(dir, seg)
            DispatchQueue.main.async { self?.segments.append(seg) }
        }, onIdle: { [weak self] in
            DispatchQueue.main.async { self?.didFinish() }
        })
        do {
            let pipe = try StreamPipeline(source: Source.mic, wavURL: Sessions.audio(dir), worker: worker)
            let mic = MicCapture()
            try mic.start { [weak self] samples in
                pipe.feed(samples)
                let elapsed = pipe.elapsedMs, level = pipe.level, backlog = worker.backlogMs
                DispatchQueue.main.async {
                    guard let self, self.recording else { return }
                    self.elapsedMs = elapsed
                    self.backlogMs = backlog
                    self.micLevels.removeFirst(); self.micLevels.append(level)
                }
            }
            self.mic = mic; self.pipe = pipe; self.worker = worker; sessionDir = dir
        } catch {
            worker.close()
            self.error = "Mikrofon: \(error.localizedDescription)"
            return
        }
        segments = []
        speakerNames = [Source.mic: "Mina"]
        elapsedMs = 0; backlogMs = 0
        recording = true
        refreshSessions()
        selected = dir
        AppLog.i("Rec", "start \(dir.lastPathComponent) lang=\(lang) model=\(model)")
    }

    func stop() {
        guard recording else { return }
        recording = false
        finishing = true
        mic?.stop()          // ootab, kuni kogu saabunud heli on pipe-le antud
        pipe?.finish()       // viimane tükk järjekorda, WAV kinni
        worker?.close()      // töölõim teeb järjekorra tühjaks ja kutsub didFinish
        mic = nil; pipe = nil
        micLevels = Array(repeating: 0, count: micLevels.count)
    }

    private func didFinish() {
        finishing = false
        backlogMs = 0
        worker = nil
        AppLog.i("Rec", "stop \(sessionDir?.lastPathComponent ?? "") \(formatClock(elapsedMs))")
        refreshSessions()
    }

    /// Äpp sulgub salvestamise ajal: pane WAV korralikult kinni.
    func emergencyStop() {
        if recording { mic?.stop(); pipe?.finish() }
        WhisperEngine.shared.unload()
    }
}
