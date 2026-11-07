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
            ContentView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .frame(minWidth: 820, minHeight: 440)
                .onAppear { delegate.model = model }
        }
        .commands {
            CommandMenu("Salvestus") {
                Button(model.recording ? "Lõpeta salvestamine" : "Alusta salvestamist") { model.toggle() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.finishing)
                Divider()
                Picker("Keel", selection: $model.lang) {
                    Text("Eesti (et)").tag("et"); Text("English (en)").tag("en")
                }.disabled(model.recording)
            }
        }
    }
}

enum Theme {
    static let font = Font.system(size: 13, design: .monospaced)
    static let small = Font.system(size: 11, design: .monospaced)
    static let bg = Color(red: 0.08, green: 0.08, blue: 0.09)
    static let panel = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let dim = Color(white: 0.5)
    static let rec = Color(red: 0.95, green: 0.27, blue: 0.27)
    static func speaker(_ s: Int) -> Color {
        switch s {
        case 0: return Color(red: 0.45, green: 0.78, blue: 0.95)   // Mina
        case 1: return Color(red: 0.95, green: 0.75, blue: 0.40)   // Nemad
        default: return Color(red: 0.70, green: 0.85, blue: 0.55)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var m: AppModel

    var body: some View {
        HSplitView {
            SessionList().frame(minWidth: 170, idealWidth: 200, maxWidth: 300)
            VStack(spacing: 0) {
                StatusBar()
                Divider()
                if let e = m.error {
                    Text(e).font(Theme.small).foregroundStyle(Theme.rec)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                }
                TranscriptView()
            }
            .frame(minWidth: 520)
            .background(Theme.bg)
        }
        .font(Theme.font)
    }
}

struct SessionList: View {
    @EnvironmentObject var m: AppModel
    static let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "dd.MM.yyyy HH:mm"; return f }()

    var body: some View {
        List(m.sessions, id: \.self, selection: $m.selected) { dir in
            VStack(alignment: .leading, spacing: 2) {
                Text(Sessions.title(dir) ?? Sessions.startedAt(dir).map { Self.fmt.string(from: $0) } ?? dir.lastPathComponent)
                    .font(Theme.font).lineLimit(1)
                Text("\(formatClock(Sessions.durationMs(dir))) · \(Sessions.lang(dir))")
                    .font(Theme.small).foregroundStyle(Theme.dim)
            }
            .tag(dir)
        }
        .disabled(m.recording)
        .scrollContentBackground(.hidden)
        .background(Theme.panel)
    }
}

struct StatusBar: View {
    @EnvironmentObject var m: AppModel
    static let bars = Array("▁▂▃▄▅▆▇█")

    func meter(_ levels: [Float]) -> String {
        String(levels.map { l in Self.bars[min(7, Int((min(1, l.squareRoot() * 1.4)) * 7.99))] })
    }

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if m.recording {
                    Text("● REC ").foregroundStyle(Theme.rec) + Text(formatClock(m.elapsedMs, forceHours: true))
                } else if m.finishing {
                    Text("◐ lõpetab… ").foregroundStyle(.yellow) + Text(String(format: "lag %.1fs", Double(m.backlogMs) / 1000))
                } else {
                    Text("○ valmis").foregroundStyle(Theme.dim)
                }
            }
            sep
            Text("mic ").foregroundStyle(Theme.dim) + Text(meter(m.micLevels)).foregroundStyle(Theme.speaker(0))
            sep
            Text(String(format: "lag %.1fs", Double(m.backlogMs) / 1000))
                .foregroundStyle(m.backlogMs > 5000 ? Theme.rec : .primary)
            sep
            Text(m.lang)
            sep
            Text(m.model)
            sep
            switch m.modelState {
            case .ready: Text("Metal")
            case .loading: Text("laadin…").foregroundStyle(.yellow)
            case .failed: Text("mudel puudub").foregroundStyle(Theme.rec)
            }
            Spacer()
            Picker("", selection: $m.lang) { Text("EST").tag("et"); Text("ENG").tag("en") }
                .pickerStyle(.segmented).frame(width: 100).disabled(m.recording || m.finishing)
            Picker("", selection: $m.model) { ForEach(AppModel.models, id: \.self) { Text($0).tag($0) } }
                .frame(width: 80).disabled(m.recording || m.finishing)
            Button(action: m.toggle) {
                Text(m.recording ? "■ Lõpeta" : "● Salvesta").frame(width: 80)
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(m.finishing || m.modelState != .ready)
            .padding(.leading, 8)
        }
        .font(Theme.font)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.panel)
        .help("⌘R alusta/lõpeta")
    }

    var sep: some View { Text("  |  ").foregroundStyle(Theme.dim) }
}

struct TranscriptView: View {
    @EnvironmentObject var m: AppModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if m.segments.isEmpty {
                        Text(m.recording ? "Kuulan… tekst ilmub lause haaval ~1 s pärast lause lõppu."
                             : "⌘R – alusta salvestamist. Vasakult saad avada varasemaid salvestisi.")
                            .foregroundStyle(Theme.dim)
                    }
                    ForEach(Array(m.segments.enumerated()), id: \.offset) { i, s in
                        row(s).id(i)
                    }
                }
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: m.segments.count) { _, n in
                if n > 0 { withAnimation { proxy.scrollTo(n - 1, anchor: .bottom) } }
            }
        }
    }

    func row(_ s: Segment) -> some View {
        var t = Text("[\(formatClock(s.startMs, forceHours: true))] ").foregroundStyle(Theme.dim)
        if let name = m.speakerLabel(s.speaker) {
            t = t + Text("\(name): ").foregroundStyle(Theme.speaker(s.speaker))
        }
        return (t + Text(s.text)).font(Theme.font).fixedSize(horizontal: false, vertical: true)
    }
}
