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
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
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
                .onAppear { delegate.model = model }
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
            SettingsView().environmentObject(model).preferredColorScheme(.dark)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        Form {
            Picker("Mudel", selection: $m.model) {
                Text("q8_0 – soovitatud (874 MB, kvaliteet = f16)").tag("q8_0")
                Text("f16 – originaal (1,6 GB)").tag("f16")
                Text("q5_0 – väiksem (574 MB)").tag("q5_0")
            }.disabled(m.busy || m.job != nil)
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
        .frame(width: 560)
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
