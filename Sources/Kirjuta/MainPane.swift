import SwiftUI
import KirjutaCore

/// Parem paan: käimasolev salvestis (LiveView) või valitud salvestis (DetailView).
struct MainPane: View {
    @EnvironmentObject var m: AppModel

    var body: some View {
        ZStack(alignment: .bottom) {
            GridBackground()
            Group {
                if m.isLiveSelected {
                    LiveView()
                } else if let dir = m.selected {
                    DetailView(dir: dir).id(dir)
                } else {
                    VStack(spacing: 14) {
                        Text("— VALMIS —").label(K.accent)
                        Text("Vajuta punast nuppu (⌘R) ja räägi – tekst ilmub lause haaval.\nLohista helifail siia, et see üles kirjutada.\nKõik töötab selles arvutis, internetita.")
                            .font(.system(size: 15)).foregroundStyle(K.textDim).multilineTextAlignment(.center).lineSpacing(6)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            if let t = m.toast {
                Banner(text: t) { EmptyView() }.frame(maxWidth: 420)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: m.toast)
    }
}

/// Pealkirjariba (sama kõrgus mõlemas vaates).
struct PaneHeader<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) { leading; Spacer(); trailing }
                .padding(.horizontal, 18).frame(height: 44)
                .padding(.top, 22)
            HLine()
        }
        .background(K.bg.opacity(0.92))
    }
}

/// Ühe lõigu rida: ajatempel vasakul, tekst paremal; uus lõik „trükitakse“ ekraanile.
struct SegmentRow: View {
    let seg: Segment
    var active = false
    var dim = false
    var animate = false
    var onTap: (() -> Void)?
    @State private var shown: Int?
    @State private var hover = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(formatClock(seg.startMs)).font(K.stamp).foregroundStyle(active ? K.accent : K.textFaint)
                .frame(width: 56, alignment: .leading)
            Text(shown.map { String(seg.text.prefix($0)) } ?? seg.text)
                .font(K.body).lineSpacing(5)
                .foregroundStyle(dim ? K.textDim : K.text)
                .italic(dim)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 7).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(active ? K.accent.opacity(0.07) : (hover && onTap != nil ? K.surface.opacity(0.7) : .clear)))
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
        .onHover { hover = $0 }
        .task(id: seg.text) {
            guard animate else { return }
            let n = seg.text.count
            let step = UInt64(min(22, max(4, 900 / max(n, 1))))
            shown = 0
            while let s = shown, s < n {
                try? await Task.sleep(nanoseconds: step * 1_000_000)
                shown = s + 1
            }
            shown = nil
        }
    }
}

struct SpeakerHeader: View {
    let name: String
    let speaker: Int
    var onTap: (() -> Void)?
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(K.speaker(speaker)).frame(width: 6, height: 6)
            Text(name.uppercased()).label(K.speaker(speaker), size: 10)
                .onTapGesture { onTap?() }
                .help(onTap != nil ? "Klõpsa, et nime muuta" : "")
        }
        .padding(.leading, 62).padding(.top, 14).padding(.bottom, 2)
    }
}

// MARK: - Käimasolev salvestis

struct LiveView: View {
    @EnvironmentObject var m: AppModel

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader {
                RecLed(active: m.recording, size: 7)
                Text(m.recording ? "SALVESTAB" : "LÕPETAB").label(m.recording ? K.rec : K.text, tracking: 3)
                Text(formatClock(m.elapsedMs, forceHours: true)).label(K.textDim, tracking: 1)
            } trailing: {
                Text(statusLine).label(K.textFaint, size: 10, tracking: 1)
                Text(m.liveLang == "en" ? "ENG" : "EST").label(K.accent).padding(.leading, 8)
                    .help(m.lang == "auto" ? "Keel tuvastatakse automaatselt" : "Keel on seadetes lukustatud")
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(m.liveSegments.enumerated()), id: \.offset) { i, s in
                            if s.speaker >= 0 && (i == 0 || m.liveSegments[i - 1].speaker != s.speaker) {
                                SpeakerHeader(name: m.speakerLabel(s.speaker), speaker: s.speaker)
                            }
                            SegmentRow(seg: s, animate: i == m.liveSegments.count - 1)
                        }
                        ForEach(m.interim.keys.sorted(), id: \.self) { src in
                            if let it = m.interim[src] {
                                SegmentRow(seg: Segment(startMs: it.start, endMs: it.start, text: it.text, speaker: src), dim: true)
                            }
                        }
                        LiveCursor(label: cursorLabel)
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 18).padding(.vertical, 12)
                }
                .onChange(of: m.liveSegments.count) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: m.interim.values.map(\.text)) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }

            if let e = m.error {
                HLine()
                Text(e).label(K.rec, size: 10, tracking: 1).padding(10)
            }
        }
    }

    var cursorLabel: String {
        if m.finishing { return "kirjutan viimast lõiku…" }
        if m.backlogMs > 3000 { return "kirjutan · järjekorras \(m.backlogMs / 1000) s" }
        return m.interim.isEmpty ? "kuulan" : "kirjutan…"
    }

    var statusLine: String {
        String(format: "lag %.1fs · %@ · Metal", Double(m.backlogMs) / 1000, m.model) + (m.lang == "auto" ? " · auto" : "")
    }
}

/// Vilkuv kursor = „kuulan“.
struct LiveCursor: View {
    let label: String
    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(K.accent).frame(width: 9, height: 18).modifier(Blink(active: true, period: 0.5))
            Text(label).label(K.textFaint)
        }
        .padding(.leading, 62).padding(.vertical, 10)
    }
}

// MARK: - Valitud salvestis

struct DetailView: View {
    @EnvironmentObject var m: AppModel
    let dir: URL
    @StateObject private var player = AudioPlayer()
    @State private var renaming: Int?
    @State private var newName = ""

    var job: JobState? { m.job?.dir == dir ? m.job : nil }

    var body: some View {
        let segs = m.segments
        let active = activeStart(segs)
        VStack(spacing: 0) {
            PaneHeader {
                Text(Export.displayTitle(dir)).label(K.text).lineLimit(1).truncationMode(.middle)
                if Sessions.isPinned(dir) { Text("▲").font(K.mono(10)).foregroundStyle(K.accent) }
            } trailing: {
                Button { m.showInFinder(dir) } label: { Image(systemName: "folder").foregroundStyle(K.textDim) }
                    .buttonStyle(.plain).help("Näita Finderis")
                Button { m.delete(dir) } label: { Image(systemName: "trash").foregroundStyle(K.textDim) }
                    .buttonStyle(.plain).help("Kustuta (saab tagasi võtta)").disabled(job != nil).padding(.leading, 10)
            }
            if let job {
                VStack(alignment: .leading, spacing: 6) {
                    Text(job.phase + (job.progress >= 0 ? " · \(Int(job.progress * 100))%" : "…")).label(K.accent)
                    ProgressLine(progress: job.progress)
                }
                .padding(.horizontal, 18).padding(.vertical, 10)
                HLine()
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if segs.isEmpty {
                            Text(job != nil ? "kirjutan…" : "(teksti ei tuvastatud)").font(K.body).foregroundStyle(K.textFaint)
                                .frame(maxWidth: .infinity).padding(.top, 60)
                        }
                        ForEach(Array(segs.enumerated()), id: \.offset) { i, s in
                            if s.speaker >= 0 && (i == 0 || segs[i - 1].speaker != s.speaker) {
                                SpeakerHeader(name: m.speakerLabel(s.speaker), speaker: s.speaker) {
                                    newName = m.speakerLabel(s.speaker); renaming = s.speaker
                                }
                            }
                            SegmentRow(seg: s, active: s.startMs == active) { player.seek(s.startMs, play: true) }
                                .id(i)
                        }
                    }
                    .padding(.horizontal, 18).padding(.vertical, 12)
                }
                .onChange(of: active) { _, a in
                    if player.playing, let i = segs.firstIndex(where: { $0.startMs == a }) {
                        withAnimation { proxy.scrollTo(i, anchor: .center) }
                    }
                }
            }

            HLine()
            VStack(spacing: 12) {
                if job?.phase != Jobs.Phase.decode.rawValue {
                    PlayerBar(player: player).padding(.horizontal, 18)
                }
                HStack(spacing: 8) {
                    Menu {
                        ForEach(Export.Format.allCases) { f in Button(f.label) { m.export(f) } }
                    } label: {
                        Text("TEKST ↗").label(K.text, tracking: 1.5)
                    }
                    .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(K.line))
                    .fixedSize()
                    Chip(title: "HELI ↗") { m.exportAudio() }
                    Chip(title: "KOPEERI") { m.copyText() }
                    if job == nil && m.job == nil && !m.busy {
                        Chip(title: Sessions.isRefined(dir) ? "TÄPSUSTA ↻" : "TÄPSUSTA", accent: true) { m.refineSelected() }
                            .help("Kogu heli uuesti täis 30 s akende ja beam 2-ga (⌘T). Praegune tekst jääb varuks.")
                    }
                }
                Text("kestus \(formatClock(Sessions.durationMs(dir))) · \(Sessions.lang(dir) == "en" ? "inglise" : "eesti") keel · \(segs.count) lõiku")
                    .font(K.stamp).foregroundStyle(K.textFaint)
            }
            .padding(.top, 14).padding(.bottom, 18)
            .frame(maxWidth: .infinity)
            .background(K.bg)
        }
        .onAppear { player.load(Sessions.audio(dir), durationMs: Sessions.durationMs(dir)) }
        .onDisappear { player.stop() }
        .alert("Nimeta kõneleja", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Nimi", text: $newName)
            Button("Salvesta") {
                if let s = renaming {
                    var names = Sessions.speakerNames(dir); names[s] = String(newName.prefix(40))
                    Sessions.setSpeakerNames(dir, names); m.loadSelected()
                }
                renaming = nil
            }
            Button("Loobu", role: .cancel) { renaming = nil }
        }
    }

    /// Mängitava lõigu algus (esiletõstmiseks).
    func activeStart(_ segs: [Segment]) -> Int64? {
        if !player.playing && player.posMs == 0 { return nil }
        return segs.last { $0.startMs <= player.posMs + 150 }?.startMs
    }
}
