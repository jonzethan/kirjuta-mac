import AppKit
import SwiftUI
import KirjutaCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model?.emergencyStop() }
    }
    /// Akna sulgemisel jääb äpp menüüribale (dikteerimise kiirklahv töötab edasi).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct KirjutaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Kirjuta", id: "main") {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear { delegate.model = model; model.dictation.registerHotkey() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(model.recording ? "Lõpeta salvestamine" : "Alusta salvestamist") { model.toggleRecording() }
                    .keyboardShortcut("r").disabled(!model.recording && !model.canRecord)
                Button("Ava helifail…") { model.pickAudioFile() }
                    .keyboardShortcut("o").disabled(model.busy || model.job != nil)
            }
            CommandMenu("Salvestis") {
                Menu("Ekspordi tekst") {
                    ForEach(Export.Format.allCases) { f in Button(f.label) { model.export(f) } }
                }.disabled(model.selected == nil)
                Button("Ekspordi tekst (.txt)") { model.export(.txt) }
                    .keyboardShortcut("e").disabled(model.selected == nil || model.isLiveSelected)
                Button("Ekspordi heli (.wav)") { model.exportAudio() }
                    .disabled(model.selected == nil || model.isLiveSelected)
                Button("Kopeeri tekst") { model.copyText() }
                    .keyboardShortcut("c", modifiers: [.command, .shift]).disabled(model.selected == nil)
                Divider()
                Button("Täpsusta") { model.refineSelected() }
                    .keyboardShortcut("t").disabled(model.selected == nil || model.busy || model.job != nil)
                Divider()
                Button("Kinnita / vabasta") { if let d = model.selected { model.togglePin(d) } }
                    .disabled(model.selected == nil)
                Button("Näita Finderis") { if let d = model.selected { model.showInFinder(d) } }
                    .disabled(model.selected == nil)
                Button("Kustuta") { if let d = model.selected { model.delete(d) } }
                    .keyboardShortcut(.delete).disabled(model.selected == nil || model.isLiveSelected)
            }
        }
        Settings {
            SettingsView().environmentObject(model).environmentObject(model.dictation).preferredColorScheme(.dark)
        }
        MenuBarExtra {
            MenuBarMenu().environmentObject(model).environmentObject(model.dictation)
        } label: {
            MenuBarIcon(dictation: model.dictation, model: model)
        }
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("Üldine", systemImage: "gearshape") }
            DictationSettings().tabItem { Label("Dikteerimine", systemImage: "mic") }
        }
        .frame(width: 600)
    }
}

struct GeneralSettings: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        Form {
            Picker("Mudel", selection: $m.model) {
                let labels = ["q8_0": "q8_0 – soovitatud (874 MB, kvaliteet = f16)", "f16": "f16 – originaal (1,6 GB)",
                              "q5_0": "q5_0 – väiksem (574 MB)"]
                ForEach(Settings.availableModels, id: \.self) { Text(labels[$0] ?? $0).tag($0) }
            }.disabled(m.busy || m.job != nil || Settings.availableModels.count < 2)
            Picker("Keel", selection: $m.lang) {
                Text("Automaatne (eesti / inglise)").tag("auto")
                Text("Ainult eesti").tag("et")
                Text("Ainult inglise").tag("en")
            }.disabled(m.busy)
            Picker("Kõnelejad", selection: Binding(get: { Settings.speakers }, set: { Settings.speakers = $0; m.objectWillChange.send() })) {
                Text("Eristab automaatselt").tag(-1)
                ForEach(2...5, id: \.self) { Text("\($0) kõnelejat").tag($0) }
                Text("Ei erista").tag(0)
            }
            Toggle("Täpsusta automaatselt pärast salvestamist", isOn: Binding(
                get: { Settings.autoRefine }, set: { Settings.autoRefine = $0; m.objectWillChange.send() }))
            LabeledContent("Mudelite kaust", value: Settings.modelsDir)
            LabeledContent("Salvestised") {
                Button(Sessions.root.path) { NSWorkspace.shared.open(Sessions.root) }.buttonStyle(.link)
            }
            LabeledContent("Logi") {
                Button("kirjuta.log") { NSWorkspace.shared.open(Settings.dataDir.appendingPathComponent("kirjuta.log")) }.buttonStyle(.link)
            }
        }
        .padding(20)
    }
}

struct DictationSettings: View {
    @EnvironmentObject var d: DictationController
    @State private var words = Settings.magicWords
    @State private var stopWords = Settings.stopWords
    @State private var silence = Settings.dictSilenceSec
    @State private var postSend = Settings.dictPostSendSec
    @State private var save = Settings.saveDictations
    @State private var trusted = Typer.isTrusted

    var body: some View {
        Form {
            LabeledContent("Kiirklahv") { HotkeyRecorder { d.registerHotkey() } }
            TextField("Võlusõnad (saadab, vajutab Enter)", text: $words)
                .onChange(of: words) { _, v in Settings.magicWords = v }
            TextField("Lõpusõnad (lõpetab ilma saatmata)", text: $stopWords)
                .onChange(of: stopWords) { _, v in Settings.stopWords = v }
            Text("Komaga eraldatult. Sõna peab olema öeldud eraldi, pärast väikest pausi.")
                .font(.caption).foregroundStyle(.secondary)
            Stepper("Pärast saatmist ootab uut juttu: \(Int(postSend)) s", value: $postSend, in: 1...30, step: 1)
                .onChange(of: postSend) { _, v in Settings.dictPostSendSec = v }
            Stepper("Lõpetab ise pärast vaikust: \(Int(silence)) s", value: $silence, in: 5...300, step: 5)
                .onChange(of: silence) { _, v in Settings.dictSilenceSec = v }
            Toggle("Salvesta dikteerimised ka salvestiste nimekirja", isOn: $save)
                .onChange(of: save) { _, v in Settings.saveDictations = v }
            LabeledContent("Teksti sisestamise luba") {
                HStack {
                    Text(trusted ? "olemas ✓" : "puudub").foregroundStyle(trusted ? .green : .orange)
                    if !trusted {
                        Button("Ava Hõlbustuse seaded") {
                            Typer.requestTrust()
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                    }
                }
            }
        }
        .padding(20)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in trusted = Typer.isTrusted }
    }
}

/// Klõpsa ja vajuta uus klahvikombinatsioon (vähemalt üks ⌘⌥⌃ või F-klahv).
struct HotkeyRecorder: View {
    var onChange: () -> Void
    @State private var recording = false
    @State private var label = Settings.dictKeyLabel
    @State private var monitor: Any?

    var body: some View {
        Button(recording ? "vajuta klahve…" : label) { recording ? stopRec() : startRec() }
            .font(.system(.body, design: .monospaced))
            .onDisappear { stopRec() }
    }

    private func startRec() {
        recording = true
        GlobalHotkey.shared.unregister()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            let flags = e.modifierFlags.intersection([.command, .option, .control, .shift])
            if e.keyCode == 53 && flags.isEmpty { stopRec(); onChange(); return nil } // Esc = tühista
            let isF = (96...122).contains(Int(e.keyCode))
            guard !flags.subtracting(.shift).isEmpty || isF else { NSSound.beep(); return nil }
            Settings.dictKeyCode = Int(e.keyCode)
            Settings.dictModifiers = GlobalHotkey.carbon(flags)
            Settings.dictKeyLabel = GlobalHotkey.label(keyCode: Int(e.keyCode), flags: flags, chars: e.charactersIgnoringModifiers)
            label = Settings.dictKeyLabel
            stopRec(); onChange()
            return nil
        }
    }

    private func stopRec() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// Menüüriba ikoon: ring + täpp (mall); dikteerimise/salvestamise ajal punane.
struct MenuBarIcon: View {
    @ObservedObject var dictation: DictationController
    @ObservedObject var model: AppModel
    var body: some View {
        Image(nsImage: Self.image(active: dictation.active || model.busy))
    }
    static func image(active: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
            let ring = NSBezierPath(ovalIn: r.insetBy(dx: 2, dy: 2)); ring.lineWidth = 1.6
            (active ? NSColor(red: 1, green: 0.2, blue: 0.28, alpha: 1) : NSColor.black).setStroke(); ring.stroke()
            let dot = NSBezierPath(ovalIn: r.insetBy(dx: 6, dy: 6))
            (active ? NSColor(red: 1, green: 0.2, blue: 0.28, alpha: 1) : NSColor.black).setFill(); dot.fill()
            return true
        }
        img.isTemplate = !active
        return img
    }
}

struct MenuBarMenu: View {
    @EnvironmentObject var m: AppModel
    @EnvironmentObject var d: DictationController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(d.active ? "Lõpeta dikteerimine (\(Settings.dictKeyLabel))" : "Dikteeri (\(Settings.dictKeyLabel))") { d.toggle() }
            .disabled(m.busy || m.modelState != .ready)
        Button(m.recording ? "Lõpeta salvestamine" : "Salvesta koosolek / kõne") {
            m.toggleRecording(); showMain()
        }
        .disabled(d.active || (!m.recording && !m.canRecord))
        Divider()
        Button("Ava Kirjuta") { showMain() }
        SettingsLink { Text("Seaded…") }
        Divider()
        Button("Lõpeta Kirjuta") { NSApp.terminate(nil) }
    }

    private func showMain() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct RootView: View {
    @EnvironmentObject var m: AppModel
    @State private var dropTarget = false

    var body: some View {
        HStack(spacing: 0) {
            Sidebar().frame(width: 330)
            Rectangle().fill(K.line).frame(width: 1)
            MainPane()
        }
        .background(K.bg)
        .ignoresSafeArea()
        .onDrop(of: [.fileURL], isTargeted: $dropTarget) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { m.importFile(url) } }
            }
            return true
        }
        .overlay {
            if dropTarget {
                ZStack {
                    K.bg.opacity(0.85)
                    VStack(spacing: 10) {
                        Text("+ HELIFAIL").label(K.accent, size: 14, tracking: 4)
                        Text("lase lahti – fail kirjutatakse täis 30 s akendega üles").label(K.textDim, tracking: 1)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(K.accent.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])).padding(10))
            }
        }
    }
}
