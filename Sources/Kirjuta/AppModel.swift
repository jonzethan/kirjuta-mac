import AppKit
import Foundation
import KirjutaCore
import UniformTypeIdentifiers

/// Taustatöö olek (import / TÄPSUSTA).
struct JobState: Equatable {
    let dir: URL?
    let title: String
    var phase: String
    var progress: Double // < 0 = määramata
    var cancellable = false // TÄPSUSTA: uus salvestus katkestab selle (reaalaja-tekst jääb alles)
}

/// Lõimekindel katkestuslipp taustatööle.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    var isSet: Bool { lock.withLock { v } }
    func set() { lock.withLock { v = true } }
}

@MainActor
final class AppModel: ObservableObject {
    enum ModelState: Equatable { case loading, ready, failed(String) }
    static let levelCount = 56
    static let models = ["q8_0", "f16", "q5_0"]

    // salvestamine
    @Published var recording = false
    @Published var finishing = false
    @Published var liveDir: URL?
    @Published var liveSegments: [Segment] = []
    @Published var interim: [Int: (start: Int64, text: String)] = [:]
    @Published var elapsedMs: Int64 = 0
    @Published var levels: [Float] = Array(repeating: 0, count: levelCount)
    @Published var backlogMs: Int64 = 0
    /// Praegu tuvastatud keel (et/en) salvestamise ajal.
    @Published var liveLang = "et"

    // nimekiri ja valitud salvestis
    @Published var sessions: [Sessions.Info] = []
    @Published var selected: URL? { didSet { if selected != oldValue { loadSelected() } } }
    @Published var segments: [Segment] = []
    @Published var speakerNames: [Int: String] = [:]
    @Published var undo: URL?

    // muu
    @Published var job: JobState?
    private var jobCancel: CancelFlag?
    /// Kas salvestamist saab alustada (TÄPSUSTA katkestatakse vajadusel).
    var canRecord: Bool { !finishing && modelState == .ready && (job == nil || job!.cancellable) }
    @Published var error: String?
    @Published var toast: String?
    @Published var modelState: ModelState = .loading
    @Published var lang: String = Settings.lang { didSet { Settings.lang = lang } }
    @Published var model: String = Settings.model { didSet { if model != oldValue { Settings.model = model; loadModel() } } }

    private var mic: MicCapture?
    private var pipe: StreamPipeline?
    private var worker: TranscribeWorker?
    private var tracker: LangTracker?
    private var undoTask: Task<Void, Never>?

    var busy: Bool { recording || finishing }
    var isLiveSelected: Bool { selected != nil && selected == liveDir && busy }

    init() {
        Sessions.emptyTrash()
        refreshSessions()
        loadModel()
    }

    // MARK: mudel

    func loadModel() {
        modelState = .loading
        let path = Settings.modelPath(model)
        Task.detached {
            let ok = WhisperEngine.shared.load(path: path)
            await MainActor.run { self.modelState = ok ? .ready : .failed("Mudelit ei leitud: \(path)") }
        }
    }

    // MARK: nimekiri

    func refreshSessions() {
        let current = busy ? liveDir : nil
        sessions = Sessions.list().map { Sessions.info($0) }.filter { $0.dir != current || busy }
    }

    func loadSelected() {
        guard let dir = selected else { segments = []; speakerNames = [:]; return }
        if dir == liveDir && busy { segments = liveSegments } else { segments = Sessions.loadSegments(dir) }
        speakerNames = Sessions.speakerNames(dir)
    }

    func speakerLabel(_ s: Int) -> String {
        if let n = speakerNames[s] { return n }
        return Sessions.speakerName([:], s)
    }

    func delete(_ dir: URL) {
        guard dir != liveDir || !busy, dir != job?.dir else { return }
        if selected == dir { selected = nil }
        undo = Sessions.moveToTrash(dir)
        refreshSessions()
        undoTask?.cancel()
        undoTask = Task { try? await Task.sleep(for: .seconds(5)); if !Task.isCancelled { undo = nil } }
    }

    func restoreUndo() {
        guard let u = undo else { return }
        Sessions.restore(u)
        undo = nil
        refreshSessions()
        selected = Sessions.root.appendingPathComponent(u.lastPathComponent)
    }

    func togglePin(_ dir: URL) {
        Sessions.setPinned(dir, !Sessions.isPinned(dir))
        refreshSessions()
    }

    func showInFinder(_ dir: URL) { NSWorkspace.shared.activateFileViewerSelecting([dir]) }

    // MARK: salvestamine

    func toggleRecording() {
        if recording { stop() } else if !finishing { Task { await start() } }
    }

    func start() async {
        error = nil
        if let j = job, j.cancellable { jobCancel?.set() } // TÄPSUSTA katkeb, salvestus läheb kohe käima
        else if job != nil { error = "Faili kirjutamine käib – oota, kuni see lõpeb"; return }
        guard modelState == .ready else { error = "Mudel pole veel laaditud"; return }
        guard await MicCapture.requestPermission() else {
            error = "Mikrofoni luba puudub: Süsteemiseaded → Privaatsus ja turvalisus → Mikrofon → lülita „Kirjuta“ sisse"
            return
        }
        let dir = Sessions.create()
        let lang = self.lang
        let tracker = LangTracker(mode: lang, initial: lang == "en" ? "en" : "et")
        Sessions.setLang(dir, tracker.current)
        Sessions.setSpeakerNames(dir, [Source.mic: "Mina"])
        let worker = TranscribeWorker(lang: tracker, onSegment: { [weak self] seg in
            Sessions.appendSegment(dir, seg)
            let l = tracker.current
            DispatchQueue.main.async { self?.addLive(seg); self?.liveLang = l }
        }, onInterim: { [weak self] source, start, text in
            DispatchQueue.main.async { self?.setInterim(source, start, text) }
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
                    self.levels.removeFirst(); self.levels.append(level)
                }
            }
            self.mic = mic; self.pipe = pipe; self.worker = worker; self.tracker = tracker
        } catch {
            worker.close()
            try? FileManager.default.removeItem(at: dir)
            self.error = "Mikrofon: \(error.localizedDescription)"
            return
        }
        liveDir = dir
        liveLang = tracker.current
        liveSegments = []
        interim = [:]
        elapsedMs = 0; backlogMs = 0
        recording = true
        refreshSessions()
        selected = dir
        loadSelected()
        AppLog.i("Rec", "start \(dir.lastPathComponent) lang=\(lang) model=\(model)")
    }

    private func addLive(_ seg: Segment) {
        liveSegments.append(seg)
        if let i = interim[seg.speaker], i.start < seg.endMs { interim[seg.speaker] = nil }
        if selected == liveDir { segments = liveSegments }
    }

    private func setInterim(_ source: Int, _ start: Int64, _ text: String) {
        guard busy else { return }
        if text.isEmpty { interim[source] = nil } else { interim[source] = (start, text) }
    }

    func stop() {
        guard recording else { return }
        recording = false
        finishing = true
        mic?.stop()          // ootab, kuni kogu saabunud heli on pipe-le antud
        pipe?.finish()       // viimane tükk järjekorda, WAV kinni
        worker?.close()      // töölõim teeb järjekorra tühjaks ja kutsub didFinish
        mic = nil; pipe = nil
        levels = Array(repeating: 0, count: Self.levelCount)
    }

    private func didFinish() {
        finishing = false
        backlogMs = 0
        interim = [:]
        worker = nil
        if let dir = liveDir, let t = tracker { Sessions.setLang(dir, t.dominant) }
        tracker = nil
        AppLog.i("Rec", "stop \(liveDir?.lastPathComponent ?? "") \(formatClock(elapsedMs))")
        refreshSessions()
        loadSelected()
        // täpne ülekirjutus kohe taustal (Macis ~10x kiirem kui reaalaeg)
        if Settings.autoRefine, let dir = liveDir, elapsedMs >= 3000, job == nil { refine(dir) }
    }

    /// Äpp sulgub salvestamise ajal: pane WAV korralikult kinni.
    func emergencyStop() {
        if recording { mic?.stop(); pipe?.finish() }
        WhisperEngine.shared.unload()
    }

    // MARK: import ja TÄPSUSTA

    static let audioTypes: [UTType] = [.audio, .movie, .mpeg4Movie, .quickTimeMovie]

    func pickAudioFile() {
        let p = NSOpenPanel()
        p.allowedContentTypes = Self.audioTypes
        p.allowsMultipleSelection = false
        p.message = "Vali helifail, mida üles kirjutada"
        if p.runModal() == .OK, let url = p.url { importFile(url) }
    }

    func importFile(_ url: URL) {
        guard canRunJob() else { return }
        let lang = self.lang
        job = JobState(dir: nil, title: url.lastPathComponent, phase: Jobs.Phase.decode.rawValue, progress: -1)
        Task.detached {
            do {
                let dir = try Jobs.importFile(url, lang: lang, created: { d in
                    DispatchQueue.main.async {
                        self.job = JobState(dir: d, title: url.lastPathComponent, phase: Jobs.Phase.decode.rawValue, progress: -1)
                        self.refreshSessions(); self.selected = d
                    }
                }, progress: { phase, p in
                    DispatchQueue.main.async {
                        self.job?.phase = phase.rawValue; self.job?.progress = p
                        if let d = self.job?.dir, self.selected == d { self.loadSelected() }
                    }
                })
                await MainActor.run { self.jobDone(select: dir) }
            } catch {
                await MainActor.run {
                    self.error = "Faili ei saanud avada: \(error.localizedDescription)"
                    self.jobDone(select: nil)
                }
            }
        }
    }

    func refineSelected() {
        guard let dir = selected, canRunJob(), dir != liveDir || !busy else { return }
        refine(dir)
    }

    private func refine(_ dir: URL) {
        job = JobState(dir: dir, title: Export.displayTitle(dir), phase: "TÄPSUSTAN", progress: 0, cancellable: true)
        let cancel = CancelFlag()
        jobCancel = cancel
        AppLog.i("Job", "refine \(dir.lastPathComponent)")
        Task.detached {
            Jobs.refine(dir, lang: Settings.lang, cancelled: { cancel.isSet }) { p in
                DispatchQueue.main.async {
                    self.job?.progress = p
                    if self.selected == dir { self.loadSelected() }
                }
            }
            await MainActor.run { self.jobDone(select: dir) }
        }
    }

    private func canRunJob() -> Bool {
        if job != nil { error = "Üks töö juba käib – oota, kuni see lõpeb"; return false }
        if busy { error = "Salvestamine käib – lõpeta see enne"; return false }
        if modelState != .ready { error = "Mudel pole veel laaditud"; return false }
        error = nil
        return true
    }

    private func jobDone(select dir: URL?) {
        job = nil
        jobCancel = nil
        refreshSessions()
        if let dir, !busy { selected = dir }
        loadSelected()
    }

    // MARK: eksport

    func export(_ f: Export.Format) {
        guard let dir = selected else { return }
        let p = NSSavePanel()
        p.nameFieldStringValue = "kirjuta-\(dir.lastPathComponent)\(f == .txtPlain ? "-tekst" : "").\(f.ext)"
        p.allowedContentTypes = [UTType(filenameExtension: f.ext) ?? .plainText]
        if p.runModal() == .OK, let url = p.url {
            do { try Export.render(f, dir: dir, segs: segments).write(to: url, atomically: true, encoding: .utf8); flash("Salvestatud: \(url.lastPathComponent)") }
            catch { self.error = "Eksport: \(error.localizedDescription)" }
        }
    }

    func exportAudio() {
        guard let dir = selected else { return }
        let src = Sessions.audio(dir)
        WavWriter.repair(src)
        let p = NSSavePanel()
        p.nameFieldStringValue = "kirjuta-\(dir.lastPathComponent).wav"
        p.allowedContentTypes = [.wav]
        if p.runModal() == .OK, let url = p.url {
            try? FileManager.default.removeItem(at: url)
            do { try FileManager.default.copyItem(at: src, to: url); flash("Salvestatud: \(url.lastPathComponent)") }
            catch { self.error = "Eksport: \(error.localizedDescription)" }
        }
    }

    func copyText() {
        guard let dir = selected else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Export.plainText(dir, segments, withTimes: false), forType: .string)
        flash("Tekst kopeeritud")
    }

    func flash(_ s: String) {
        toast = s
        Task { try? await Task.sleep(for: .seconds(2.5)); if toast == s { toast = nil } }
    }
}
