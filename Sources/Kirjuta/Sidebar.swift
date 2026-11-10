import SwiftUI
import KirjutaCore

/// Vasak paan = Androidi avaekraan: ülariba, töö/salvestuse riba, salvestised päevade kaupa, keel + salvestusnupp.
struct Sidebar: View {
    @EnvironmentObject var m: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        RecLed(active: m.recording)
                        Text("KIRJUTA").font(K.mono(13, .medium)).tracking(5).foregroundStyle(K.text)
                    }
                    NeonHandle().padding(.leading, 2)
                }
                Spacer()
                if !m.busy && m.job == nil { Chip(title: "+ HELIFAIL") { m.pickAudioFile() } }
            }
            .padding(.leading, 14).padding(.trailing, 12)
            .padding(.top, 34).padding(.bottom, 10) // ruum akna nuppudele

            HLine()
            SearchBox()
            HLine()
            RefineBar()
            HLine()
            if let job = m.job { JobStrip(job: job) }
            ZStack(alignment: .bottom) {
                if m.sessions.isEmpty {
                    VStack(spacing: 12) {
                        Text("— VALMIS —").label(K.accent)
                        Text("Vajuta punast nuppu ja räägi.\nTekst ilmub lause haaval.\nKõik töötab selles arvutis, internetita.")
                            .font(.system(size: 14)).foregroundStyle(K.textDim).multilineTextAlignment(.center).lineSpacing(5)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    SessionList()
                }
                if m.undo != nil {
                    Banner(text: "Salvestis kustutatud") {
                        Button { m.restoreUndo() } label: { Text("VÕTA TAGASI").label(K.accent) }.buttonStyle(.plain)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .frame(maxHeight: .infinity)
            .animation(.easeOut(duration: 0.2), value: m.undo)

            HLine()
            RecorderDeck()
        }
        .background(K.bg)
    }

}

/// Ainus salvestuspult: suur nupp; salvestamise ajal ka lainekuju, kell ja olek.
/// Kella klõps avab käimasoleva salvestise teksti.
struct RecorderDeck: View {
    @EnvironmentObject var m: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if m.busy {
                Button { m.selected = m.liveDir } label: {
                    VStack(spacing: 8) {
                        Waveform(levels: m.levels, active: m.recording).frame(height: 30)
                        Text(formatClock(m.elapsedMs, forceHours: true)).font(K.mono(30, .light)).foregroundStyle(K.text)
                        HStack(spacing: 6) {
                            RecLed(active: m.recording, size: 5)
                            Text(m.recording ? "REC" : "LÕPETAB").label(m.recording ? K.rec : K.text, size: 10)
                            Text("·").label(K.textFaint, size: 10)
                            Text(m.liveLang == "en" ? "ENG" : "EST").label(K.accent, size: 10)
                            Text(String(format: "· lag %.1fs", Double(m.backlogMs) / 1000)).label(K.textFaint, size: 10, tracking: 1)
                        }
                    }
                    .padding(.horizontal, 22).padding(.top, 16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Näita käimasolevat salvestist")
            }
            RecordButton(recording: m.recording,
                         enabled: m.recording || m.canRecord) {
                m.toggleRecording()
            }
            .padding(.top, 16)
            Text(statusLine).label(m.error != nil && !m.busy ? K.rec : K.textFaint, size: 10, tracking: 1.5)
                .multilineTextAlignment(.center).lineLimit(3)
                .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity)
        .background(K.bg)
        .animation(.easeOut(duration: 0.2), value: m.busy)
    }

    var statusLine: String {
        if let e = m.error, !m.busy { return e }
        switch m.modelState {
        case .loading: return "laadin mudelit…"
        case .failed(let s): return s
        case .ready: break
        }
        if m.recording { return "⌘R lõpetab" }
        if m.finishing { return "kirjutan viimast lõiku…" }
        if let j = m.job { return j.cancellable ? "⌘R alustab (täpsustamine katkeb)" : "oota, fail on töös" }
        let lang = m.lang == "auto" ? "keel automaatne" : (m.lang == "en" ? "ainult inglise" : "ainult eesti")
        return "uus salvestis · ⌘R · \(lang)"
    }
}

struct JobStrip: View {
    @EnvironmentObject var m: AppModel
    let job: JobState
    var body: some View {
        VStack(spacing: 0) {
            Button { if let d = job.dir { m.selected = d } } label: {
                HStack(spacing: 10) {
                    Text(job.phase + (job.progress >= 0 ? " · \(Int(job.progress * 100))%" : "…")).label(K.accent)
                    Text(job.title).font(K.stamp).foregroundStyle(K.textDim).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text("AVA →").label(K.text)
                }
                .padding(.horizontal, 18).padding(.vertical, 11)
                .background(K.accent.opacity(0.06))
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
            ProgressLine(progress: job.progress)
        }
    }
}

struct ProgressLine: View {
    let progress: Double
    @State private var phase = false
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Rectangle().fill(K.line)
                if progress >= 0 {
                    Rectangle().fill(K.accent).frame(width: g.size.width * min(1, progress))
                        .animation(.linear(duration: 0.3), value: progress)
                } else {
                    Rectangle().fill(K.accent).frame(width: g.size.width * 0.3)
                        .offset(x: phase ? g.size.width * 0.7 : 0)
                        .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: phase)
                        .onAppear { phase = true }
                }
            }
        }
        .frame(height: 2)
        .clipped()
    }
}

struct SessionList: View {
    @EnvironmentObject var m: AppModel
    static let dayFormat: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "et_EE"); f.dateFormat = "EEEE, d. MMMM yyyy"; return f
    }()

    var body: some View {
        let list = m.filteredSessions
        let pinned = list.filter(\.pinned)
        let rest = list.filter { !$0.pinned }
        var days: [(String, [Sessions.Info])] = []
        for s in rest {
            let d = Self.dayFormat.string(from: s.startedAt).uppercased()
            if days.last?.0 == d { days[days.count - 1].1.append(s) } else { days.append((d, [s])) }
        }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if list.isEmpty {
                    Text("„\(m.query)“ – ei leitud").label(K.textFaint, size: 10, tracking: 1)
                        .frame(maxWidth: .infinity).padding(.top, 40)
                }
                if !pinned.isEmpty {
                    header("▲ KINNITATUD", accent: true)
                    ForEach(pinned, id: \.dir) { SessionRow(info: $0) }
                }
                ForEach(days, id: \.0) { day, items in
                    header(day)
                    ForEach(items, id: \.dir) { SessionRow(info: $0) }
                }
                Text("paremklõps: kinnita · kustuta · Finder").label(K.textFaint, size: 10, tracking: 1)
                    .frame(maxWidth: .infinity).padding(.top, 18).padding(.bottom, 70)
            }
        }
    }

    func header(_ t: String, accent: Bool = false) -> some View {
        Text(t).label(accent ? K.accent : K.textFaint, size: 10)
            .padding(.leading, 18).padding(.top, 18).padding(.bottom, 6)
    }
}

struct SessionRow: View {
    @EnvironmentObject var m: AppModel
    let info: Sessions.Info
    @State private var hover = false
    static let time: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()

    var isLive: Bool { info.dir == m.liveDir && m.busy }
    var selected: Bool { m.selected == info.dir }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.time.string(from: info.startedAt)).label(K.text, tracking: 1)
                Text(isLive ? formatClock(m.elapsedMs) : formatClock(info.durationMs)).font(K.stamp)
                    .foregroundStyle(isLive ? K.rec : K.accent)
            }
            .frame(width: 58, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                if let t = info.title {
                    Text(t).label(K.text, tracking: 0.5).lineLimit(1).truncationMode(.middle)
                }
                Text(previewText).font(.system(size: 13)).foregroundStyle(K.textDim).lineLimit(2).lineSpacing(2)
            }
            Spacer(minLength: 10)
            VStack(alignment: .trailing, spacing: 5) {
                Text(info.lang == "en" ? "ENG" : "EST").font(K.mono(9)).foregroundStyle(K.textFaint)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(K.line))
                if !info.speakers.isEmpty {
                    HStack(spacing: 2) {
                        ForEach(info.speakers.prefix(5), id: \.self) { Circle().fill(K.speaker($0)).frame(width: 5, height: 5) }
                    }
                }
                if !isLive { RefinedBadge(state: refineState) }
                if !m.query.isEmpty, !isLive {
                    let n = m.hits(in: info.dir)
                    Text("\(n) vastet").font(K.mono(9)).foregroundStyle(K.accent)
                }
                if info.pinned { Text("▲").font(K.mono(10)).foregroundStyle(K.accent) }
                if isLive { RecLed(active: m.recording, size: 5) }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(selected ? K.accent.opacity(0.07) : (hover ? K.surface : K.bg))
        .overlay(alignment: .leading) { if selected { Rectangle().fill(K.accent).frame(width: 2) } }
        .contentShape(Rectangle())
        .onTapGesture { m.selected = info.dir }
        .onHover { hover = $0 }
        .contextMenu {
            Button(info.pinned ? "▼ Vabasta" : "▲ Kinnita üles") { m.togglePin(info.dir) }
            Button("Näita Finderis") { m.showInFinder(info.dir) }
            Divider()
            Button("Kustuta", role: .destructive) { m.delete(info.dir) }.disabled(isLive || m.job?.dir == info.dir)
        }
    }

    var refineState: RefinedBadge.State {
        if m.job?.dir == info.dir && m.job?.cancellable == true { return .working }
        if m.refineQueue.contains(info.dir) { return .queued }
        return info.refined ? .refined : .raw
    }

    var previewText: String {
        if isLive { return m.liveSegments.last?.text ?? "salvestab…" }
        if m.job?.dir == info.dir && info.preview.isEmpty { return "töös…" }
        return info.preview.isEmpty ? "(tekst puudub)" : info.preview
    }
}

/// Täpsustamise olek salvestise juures: ✓ TÄPSUSTATUD, KIIRE = ainult reaalaja-tekst.
struct RefinedBadge: View {
    enum State { case refined, raw, queued, working }
    let state: State
    var body: some View {
        let (t, c): (String, Color) = switch state {
        case .refined: ("✓ TÄPSUSTATUD", K.accent)
        case .raw: ("KIIRE", K.textFaint)
        case .queued: ("OOTAB", K.textDim)
        case .working: ("TÖÖS", K.accent)
        }
        Text(t).font(K.mono(9)).foregroundStyle(c)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(state == .refined ? K.accent.opacity(0.4) : K.line))
            .help(help)
    }
    var help: String {
        switch state {
        case .refined: return "Täpsustatud: kogu heli on uuesti täpsemalt üle kirjutatud"
        case .raw: return "Täpsustamata: ainult salvestamise ajal tehtud kiire tekst"
        case .queued: return "Ootab täpsustamise järjekorras"
        case .working: return "Täpsustamine käib"
        }
    }
}

/// Riba nimekirja kohal: automaatse täpsustamise lüliti + „täpsusta kõik täpsustamata“.
struct RefineBar: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        let n = m.unrefined.filter { $0 != m.job?.dir }.count
        HStack(spacing: 8) {
            Button { m.autoRefine.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: m.autoRefine ? "checkmark.square.fill" : "square")
                        .font(.system(size: 12)).foregroundStyle(m.autoRefine ? K.accent : K.textFaint)
                    Text("AUTO-TÄPSUSTUS").label(m.autoRefine ? K.text : K.textFaint, size: 10, tracking: 1.5)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(m.autoRefine ? "Sees: pärast salvestamist kirjutatakse kogu salvestis kohe täpsemalt üle"
                               : "Väljas: salvestis jääb kiire tekstiga, täpsusta hiljem käsitsi")
            Spacer()
            if !m.refineQueue.isEmpty {
                Text("JÄRJEKORRAS \(m.refineQueue.count)").label(K.textDim, size: 10, tracking: 1)
                Button { m.cancelRefineQueue() } label: { Text("PEATA").label(K.rec, size: 10, tracking: 1.5) }
                    .buttonStyle(.plain).help("Peata täpsustamine (pooleli salvestis jääb kiire tekstiga)")
            } else if n > 0 {
                Button { m.refineAllUnrefined() } label: {
                    Text("TÄPSUSTA KÕIK (\(n))").label(K.accent, size: 10, tracking: 1.5)
                }
                .buttonStyle(.plain).disabled(m.modelState != .ready)
                .help("Kirjuta kõik täpsustamata salvestised ükshaaval täpsemalt üle. Salvestamine katkestab ja jätkab hiljem.")
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 9)
    }
}

/// Otsingulahter (⌘F): filtreerib salvestised teksti järgi; Enter = järgmine vaste, ⇧Enter / ↑ = eelmine, Esc = tühjenda.
struct SearchBox: View {
    @EnvironmentObject var m: AppModel
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(focused ? K.accent : K.textFaint)
            TextField("", text: $m.search, prompt: Text("Otsi tekstist… ⌘F").foregroundStyle(K.textFaint))
                .textFieldStyle(.plain).font(K.mono(12)).foregroundStyle(K.text)
                .focused($focused)
                .onSubmit {
                    m.stepSearch(NSEvent.modifierFlags.contains(.shift) ? -1 : 1)
                    DispatchQueue.main.async { focused = true } // Enter lõpetab muidu lahtri muutmise
                }
                .onKeyPress(.downArrow) { m.stepSearch(1); return .handled }
                .onKeyPress(.upArrow) { m.stepSearch(-1); return .handled }
                .onExitCommand { m.search = ""; focused = false }
            if !m.search.isEmpty {
                Button { m.search = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(K.textFaint)
                }.buttonStyle(.plain).help("Tühjenda (Esc)")
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 9)
        .background(focused ? K.surface : .clear)
        .onChange(of: m.searchFocus) { _, _ in focused = true }
    }
}

/// „jonzethan“ neoonsiniselt kumamas (pilt Resources/handle.png, vt scripts/make-handle.swift).
struct NeonHandle: View {
    static let image: NSImage? = Bundle.main.url(forResource: "handle", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
    var height: CGFloat = 24
    var body: some View {
        if let img = Self.image {
            Image(nsImage: img).resizable().renderingMode(.template).interpolation(.high)
                .aspectRatio(contentMode: .fit).frame(height: height)
                .foregroundStyle(K.accent)
                .shadow(color: K.accent.opacity(0.9), radius: 4)
                .shadow(color: K.accent.opacity(0.5), radius: 10)
                .help("jonzethan")
        }
    }
}
