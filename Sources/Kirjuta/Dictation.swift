import AppKit
import SwiftUI
import KirjutaCore

/// Dikteerimine: kiirklahv → mikrofon → DictationEngine → Typer (aktiivne lahter) + ujuv indikaator.
@MainActor
final class DictationController: ObservableObject {
    enum Phase: Equatable { case idle, listening, writing, awaitingSend, sent, finishing, error(String) }

    @Published var phase: Phase = .idle
    @Published var levels: [Float] = Array(repeating: 0, count: 14)
    @Published var preview = ""
    var active: Bool { switch phase { case .idle, .error: return false; default: return true } }

    weak var app: AppModel?
    private var engine: DictationEngine?
    private var mic: MicCapture?
    private let typer = Typer()
    private var hud: HUDPanel?
    private var hideTask: Task<Void, Never>?
    // salvestamine (seadetes valitav)
    private var sessionDir: URL?
    private var writer: WavWriter?
    private var savedAny = false

    func registerHotkey() {
        GlobalHotkey.shared.action = { [weak self] in self?.toggle() }
        GlobalHotkey.shared.register(keyCode: Settings.dictKeyCode, carbonModifiers: Settings.dictModifiers)
    }

    func toggle() {
        if active { stop() } else { Task { await start() } }
    }

    func start() async {
        guard let app, !active else { return }
        hideTask?.cancel()
        if app.busy { return fail("Salvestamine käib – dikteerimine pole praegu võimalik") }
        guard app.modelState == .ready else { return fail("Mudel pole veel laaditud") }
        guard await MicCapture.requestPermission() else {
            return fail("Mikrofoni luba puudub: Süsteemiseaded → Privaatsus ja turvalisus → Mikrofon → Kirjuta")
        }
        guard Typer.isTrusted else {
            Typer.requestTrust()
            return fail("Luba Kirjutal teksti sisestada: Süsteemiseaded → Privaatsus ja turvalisus → Hõlbustus → lülita „Kirjuta“ sisse")
        }
        app.cancelRefineIfRunning()

        func list(_ s: String) -> [String] { s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        let eng = DictationEngine(config: .init(magicWords: list(Settings.magicWords), stopWords: list(Settings.stopWords),
                                                silenceSec: Settings.dictSilenceSec,
                                                postSendSec: Settings.dictPostSendSec, lang: Settings.lang))
        eng.onText = { [weak self] t in self?.typer.update(to: t); self?.preview = t }
        eng.onSend = { [weak self] in self?.typer.pressReturn(); self?.preview = "" }
        eng.onLevel = { [weak self] l in guard let self else { return }; levels.removeFirst(); levels.append(l) }
        eng.onState = { [weak self] s in
            guard let self, active, phase != .finishing else { return }
            switch s {
            case .listening: phase = .listening
            case .writing: phase = .writing
            case .awaitingSend: phase = .awaitingSend
            case .sent: phase = .sent
            case .stopped: break
            }
        }
        eng.onFinal = { [weak self] seg in
            guard let self, let dir = sessionDir else { return }
            Sessions.appendSegment(dir, seg); savedAny = true
        }
        eng.onStop = { [weak self] reason in self?.didStop(reason) }

        if Settings.saveDictations {
            let dir = Sessions.create()
            Sessions.setTitle(dir, "Dikteerimine")
            Sessions.setSpeakerNames(dir, [Source.mic: "Mina"])
            Sessions.setLang(dir, Settings.lang == "en" ? "en" : "et")
            sessionDir = dir
            writer = try? WavWriter(url: Sessions.audio(dir))
        }
        let w = writer
        let m = MicCapture()
        do {
            try m.start { samples in
                eng.feed(samples)
                if let w { w.write(samples.map { Int16(max(-32768, min(32767, ($0 * 32767).rounded()))) }[...]) }
            }
        } catch {
            cleanupSession()
            return fail("Mikrofon: \(error.localizedDescription)")
        }
        engine = eng; mic = m; savedAny = false
        typer.reset()
        preview = ""
        levels = Array(repeating: 0, count: levels.count)
        phase = .listening
        showHUD()
        AppLog.i("Dict", "start")
    }

    /// Kasutaja lõpetas (kiirklahv / menüü): viimane lause kirjutatakse veel ära.
    func stop() {
        guard active, phase != .finishing else { return }
        phase = .finishing
        mic?.stop(); mic = nil
        engine?.stop()
    }

    private func didStop(_ reason: DictationEngine.StopReason) {
        mic?.stop(); mic = nil
        engine = nil
        typer.flush()
        writer?.close(); writer = nil
        if let dir = sessionDir {
            if savedAny { app?.refreshSessions() } else { try? FileManager.default.removeItem(at: dir) }
        }
        sessionDir = nil
        AppLog.i("Dict", "stop \(reason)")
        phase = .idle
        hideHUD(after: 0.4)
        app?.startNextQueued()
    }

    private func cleanupSession() {
        writer?.close(); writer = nil
        if let dir = sessionDir { try? FileManager.default.removeItem(at: dir) }
        sessionDir = nil
    }

    private func fail(_ msg: String) {
        phase = .error(msg)
        showHUD()
        hideHUD(after: 6)
    }

    // MARK: indikaator

    private func showHUD() {
        if hud == nil { hud = HUDPanel(root: DictationHUD().environmentObject(self)) }
        hud?.showAtBottomOfActiveScreen()
    }

    private func hideHUD(after s: Double) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(s * 1e9))
            guard !Task.isCancelled, let self, !self.active else { return }
            self.hud?.orderOut(nil)
            if case .error = self.phase { self.phase = .idle }
        }
    }
}

/// Ujuv paneel, mis ei võta fookust (tekst läheb edasi sinna lahtrisse, kus kursor oli).
final class HUDPanel: NSPanel {
    init<V: View>(root: V) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.size.width, height: Self.size.height),
                   styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        // läbipaistev fikseeritud ala, sisu all keskel (suurus võib muutuda ilma akent liigutamata)
        contentView = NSHostingView(rootView: VStack { Spacer(minLength: 0); root }
            .frame(width: Self.size.width, height: Self.size.height))
    }
    static let size = NSSize(width: 720, height: 180)
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func showAtBottomOfActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        let size = Self.size
        setFrame(NSRect(x: vf.midX - size.width / 2, y: vf.minY + 22, width: size.width, height: size.height), display: true)
        orderFrontRegardless()
    }
}

/// Indikaator: punane tuluke + lainekuju + olek („KUULAN“, „KIRJUTAN“, „ÜTLE „SAADA““ …).
struct DictationHUD: View {
    @EnvironmentObject var d: DictationController

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(dotColor.opacity(0.25)).frame(width: 22, height: 22)
                Circle().fill(dotColor).frame(width: 10, height: 10).modifier(Blink(active: d.active))
            }
            if d.active {
                Waveform(levels: d.levels, active: true).frame(width: 64, height: 20)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(K.mono(11, .semibold)).tracking(1.5).foregroundStyle(titleColor)
                if let sub {
                    Text(sub).font(K.mono(10)).foregroundStyle(K.textDim)
                        .lineLimit(isError ? 4 : 1).truncationMode(isError ? .tail : .head)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: isError ? 380 : nil, alignment: .leading)
                        .frame(maxWidth: 380, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(Capsule().fill(K.surface.opacity(0.97)))
        .overlay(Capsule().strokeBorder(borderColor, lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 14, y: 4)
        .padding(14)
        .fixedSize()
        .animation(.easeInOut(duration: 0.2), value: title)
    }

    var dotColor: Color {
        switch d.phase {
        case .error: return .orange
        case .sent: return K.accent
        default: return K.rec
        }
    }
    static func first(_ list: String, _ def: String) -> String {
        list.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? def
    }
    var isError: Bool { if case .error = d.phase { return true }; return false }
    var titleColor: Color { if case .error = d.phase { return .orange }; return K.text }
    var borderColor: Color { d.phase == .awaitingSend ? K.accent.opacity(0.6) : K.line }

    var title: String {
        switch d.phase {
        case .idle: return "VALMIS"
        case .listening: return "KUULAN · KIRJUTAN LAHTRISSE"
        case .writing: return "KIRJUTAN"
        case .awaitingSend:
            return "ÜTLE „\(Self.first(Settings.magicWords, "saada").uppercased())“ VÕI JÄTKA"
        case .sent: return "SAADETUD ✓"
        case .finishing: return "LÕPETAN…"
        case .error: return "EI SAA ALUSTADA"
        }
    }
    var sub: String? {
        switch d.phase {
        case .error(let m): return m
        case .sent: return "räägi edasi või ütle „\(Self.first(Settings.stopWords, "lõpeta"))“"
        default: return d.preview.isEmpty ? "\(Settings.dictKeyLabel) lõpetab" : String(d.preview.suffix(80))
        }
    }
}
