import Foundation

/// speaker = -1: kõnelejat pole määratud. Mac: 0 = Mina (mikrofon), 1 = Nemad (süsteemiheli).
public struct Segment: Sendable, Hashable {
    public var startMs: Int64
    public var endMs: Int64
    public var text: String
    public var speaker: Int
    public init(startMs: Int64, endMs: Int64, text: String, speaker: Int = -1) {
        self.startMs = startMs; self.endMs = endMs; self.text = text; self.speaker = speaker
    }
}

public enum Source {
    public static let mic = 0
    public static let system = 1
}

/// Seaded (UserDefaults).
public enum Settings {
    private static var d: UserDefaults { .standard }
    public static var lang: String {
        get { d.string(forKey: "langMode") ?? "auto" }   // auto | et | en
        set { d.set(newValue, forKey: "langMode") }
    }
    /// Pärast salvestamist kirjuta kogu salvestis automaatselt täpses režiimis üle (TÄPSUSTA).
    public static var autoRefine: Bool {
        get { d.object(forKey: "autoRefine") as? Bool ?? true }
        set { d.set(newValue, forKey: "autoRefine") }
    }
    // --- dikteerimine ---
    /// Kiirklahv: virtuaalne klahvikood + Carboni modifikaatorid (vaikimisi ⌥Space: 49 + optionKey 0x800).
    public static var dictKeyCode: Int {
        get { d.object(forKey: "dictKeyCode") as? Int ?? 49 }
        set { d.set(newValue, forKey: "dictKeyCode") }
    }
    public static var dictModifiers: Int {
        get { d.object(forKey: "dictModifiers") as? Int ?? 0x800 }
        set { d.set(newValue, forKey: "dictModifiers") }
    }
    public static var dictKeyLabel: String {
        get { d.string(forKey: "dictKeyLabel") ?? "⌥Space" }
        set { d.set(newValue, forKey: "dictKeyLabel") }
    }
    /// Võlusõnad komadega eraldatult.
    public static var magicWords: String {
        get { d.string(forKey: "magicWords") ?? "saada, send it" }
        set { d.set(newValue, forKey: "magicWords") }
    }
    /// Lõpusõnad: lõpetavad dikteerimise ilma saatmata.
    public static var stopWords: String {
        get { d.string(forKey: "stopWords") ?? "lõpeta, stop dictation" }
        set { d.set(newValue, forKey: "stopWords") }
    }
    public static var dictSilenceSec: Double {
        get { d.object(forKey: "dictSilenceSec") as? Double ?? 30 }
        set { d.set(newValue, forKey: "dictSilenceSec") }
    }
    public static var dictPostSendSec: Double {
        get { d.object(forKey: "dictPostSendSec") as? Double ?? 6 }
        set { d.set(newValue, forKey: "dictPostSendSec") }
    }
    /// Kas dikteerimised salvestatakse ka salvestiste nimekirja.
    public static var saveDictations: Bool {
        get { d.object(forKey: "saveDictations") as? Bool ?? false }
        set { d.set(newValue, forKey: "saveDictations") }
    }
    /// f16 | q8_0 | q5_0
    public static var model: String {
        get { d.string(forKey: "model") ?? "q8_0" }
        set { d.set(newValue, forKey: "model") }
    }
    public static var modelsDir: String {
        get { d.string(forKey: "modelsDir") ?? (NSHomeDirectory() + "/whisper-android/models") }
        set { d.set(newValue, forKey: "modelsDir") }
    }
    /// Kõnelejate mudelid (pyannote + wespeaker), samad mis Androidis.
    public static var diarDir: String {
        get { d.string(forKey: "diarDir") ?? (NSHomeDirectory() + "/whisper-android/third_party/diar") }
        set { d.set(newValue, forKey: "diarDir") }
    }
    /// Kõnelejad TÄPSUSTA/impordi juures: -1 = automaatne, 0 = ei erista, 2–5 = täpne arv.
    public static var speakers: Int {
        get { d.object(forKey: "speakers") as? Int ?? -1 }
        set { d.set(newValue, forKey: "speakers") }
    }
    public static func modelPath(_ name: String = model) -> String {
        modelsDir + "/taltech-et-turbo-\(name).bin"
    }
    /// Kõik andmed: ~/Kirjuta (sessions/, kirjuta.log)
    public static var dataDir: URL {
        URL(fileURLWithPath: d.string(forKey: "dataDir") ?? (NSHomeDirectory() + "/Kirjuta"))
    }
}

public func formatClock(_ ms: Int64, forceHours: Bool = false) -> String {
    let s = ms / 1000, h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    return h > 0 || forceHours ? String(format: "%02lld:%02lld:%02lld", h, m, sec) : String(format: "%02lld:%02lld", m, sec)
}

/// Salvestiste kaustad – sama vorming mis Androidis (vt SESSION_FORMAT.md).
public enum Sessions {
    static let idFormat: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"; return f
    }()

    public static var root: URL {
        let r = Settings.dataDir.appendingPathComponent("sessions")
        try? FileManager.default.createDirectory(at: r, withIntermediateDirectories: true)
        return r
    }

    public static func create() -> URL {
        let dir = root.appendingPathComponent(idFormat.string(from: Date()))
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func list() -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return items.filter { !$0.lastPathComponent.hasPrefix(".") && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    public static func startedAt(_ dir: URL) -> Date? { idFormat.date(from: dir.lastPathComponent) }

    public static func audio(_ dir: URL) -> URL { dir.appendingPathComponent("audio.wav") }
    public static func mic(_ dir: URL) -> URL { dir.appendingPathComponent("mic.wav") }
    public static func system(_ dir: URL) -> URL { dir.appendingPathComponent("system.wav") }
    static func segFile(_ dir: URL) -> URL { dir.appendingPathComponent("segments.tsv") }

    public static func lang(_ dir: URL) -> String {
        (try? String(contentsOf: dir.appendingPathComponent("lang"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "et"
    }
    public static func setLang(_ dir: URL, _ lang: String) { write(dir.appendingPathComponent("lang"), lang) }
    public static func title(_ dir: URL) -> String? {
        (try? String(contentsOf: dir.appendingPathComponent("title"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func setTitle(_ dir: URL, _ t: String) { write(dir.appendingPathComponent("title"), t) }
    public static func isPinned(_ dir: URL) -> Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent("pinned").path) }
    public static func setPinned(_ dir: URL, _ on: Bool) {
        let f = dir.appendingPathComponent("pinned")
        if on { write(f, "1") } else { try? FileManager.default.removeItem(at: f) }
    }
    public static func isRefined(_ dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent("segments.live.tsv").path) || title(dir) != nil
    }
    /// TÄPSUSTA: reaalajas tehtud tekst jääb varuks (segments.live.tsv), uus tekst kirjutatakse nullist.
    public static func archiveLiveSegments(_ dir: URL) {
        let fm = FileManager.default
        let cur = segFile(dir), live = dir.appendingPathComponent("segments.live.tsv")
        if !fm.fileExists(atPath: live.path) && fm.fileExists(atPath: cur.path) { try? fm.moveItem(at: cur, to: live) }
        else { try? fm.removeItem(at: cur) }
    }

    /// Katkestatud TÄPSUSTA: reaalaja-tekst tagasi.
    public static func restoreLiveSegments(_ dir: URL) {
        let fm = FileManager.default
        let cur = segFile(dir), live = dir.appendingPathComponent("segments.live.tsv")
        guard fm.fileExists(atPath: live.path) else { return }
        try? fm.removeItem(at: cur)
        try? fm.moveItem(at: live, to: cur)
    }

    // --- prügikast (kustuta + võta tagasi); tühjendatakse äpi järgmisel käivitusel ---
    static var trash: URL {
        let t = root.appendingPathComponent(".trash")
        try? FileManager.default.createDirectory(at: t, withIntermediateDirectories: true)
        return t
    }
    public static func moveToTrash(_ dir: URL) -> URL {
        let dest = trash.appendingPathComponent(dir.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.moveItem(at: dir, to: dest)
        return dest
    }
    public static func restore(_ trashed: URL) {
        try? FileManager.default.moveItem(at: trashed, to: root.appendingPathComponent(trashed.lastPathComponent))
    }
    public static func emptyTrash() { try? FileManager.default.removeItem(at: trash) }

    /// Nimekirja rida.
    public struct Info: Hashable, Sendable {
        public let dir: URL
        public let startedAt: Date
        public let durationMs: Int64
        public let preview: String
        public let lang: String
        public let title: String?
        public let refined: Bool
        public let pinned: Bool
        public let speakers: [Int]
    }

    public static func info(_ dir: URL) -> Info {
        WavWriter.repair(audio(dir))
        let segs = loadSegments(dir)
        let date = startedAt(dir) ?? ((try? dir.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date())
        var spk: [Int] = []
        for s in segs where s.speaker >= 0 && !spk.contains(s.speaker) { spk.append(s.speaker) }
        return Info(dir: dir, startedAt: date, durationMs: durationMs(dir),
                    preview: String(segs.map(\.text).joined(separator: " ").prefix(160)), lang: lang(dir),
                    title: title(dir), refined: isRefined(dir), pinned: isPinned(dir), speakers: spk.sorted())
    }

    /// 16 kHz mono 16-bit WAV -> näidised (otsib "data" tüki).
    public static func readWav(_ url: URL) -> [Int16] {
        guard let d = try? Data(contentsOf: url, options: .mappedIfSafe), d.count > 12 else { return [] }
        var off = 12
        while off + 8 <= d.count {
            let id = String(decoding: d[off..<(off + 4)], as: UTF8.self)
            let len = Int(d[(off + 4)..<(off + 8)].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
            if id == "data" {
                let end = min(d.count, off + 8 + (len == 0 ? d.count : len))
                let start = off + 8
                let n = (end - start) / 2
                var out = [Int16](repeating: 0, count: n)
                _ = out.withUnsafeMutableBytes { d.copyBytes(to: $0, from: start..<(start + n * 2)) }
                return out
            }
            off += 8 + len + (len & 1)
        }
        return []
    }

    /// Kõnelejate nimed: "0=Mina" ridadena.
    public static func speakerNames(_ dir: URL) -> [Int: String] {
        guard let s = try? String(contentsOf: dir.appendingPathComponent("speakers.txt"), encoding: .utf8) else { return [:] }
        var out: [Int: String] = [:]
        for l in s.split(separator: "\n") {
            guard let i = l.firstIndex(of: "="), let n = Int(l[..<i]) else { continue }
            out[n] = String(l[l.index(after: i)...])
        }
        return out
    }
    public static func setSpeakerNames(_ dir: URL, _ names: [Int: String]) {
        write(dir.appendingPathComponent("speakers.txt"), names.keys.sorted().map { "\($0)=\(names[$0]!)\n" }.joined())
    }
    public static func speakerName(_ names: [Int: String], _ speaker: Int) -> String {
        names[speaker] ?? "Kõneleja \(speaker + 1)"
    }

    // segments.tsv: algus_ms \t lõpp_ms \t tekst [\t kõneleja]
    static func line(_ s: Segment) -> String {
        let clean = s.text.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
        return "\(s.startMs)\t\(s.endMs)\t\(clean)" + (s.speaker >= 0 ? "\t\(s.speaker)" : "") + "\n"
    }

    public static func appendSegment(_ dir: URL, _ s: Segment) {
        let url = segFile(dir)
        let data = Data(line(s).utf8)
        if let fh = try? FileHandle(forWritingTo: url) {
            defer { try? fh.close() }
            _ = try? fh.seekToEnd(); try? fh.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    public static func saveSegments(_ dir: URL, _ segs: [Segment]) {
        let tmp = dir.appendingPathComponent("segments.tsv.tmp")
        write(tmp, segs.map(line).joined())
        _ = try? FileManager.default.replaceItemAt(segFile(dir), withItemAt: tmp)
    }

    public static func loadSegments(_ dir: URL) -> [Segment] {
        guard let s = try? String(contentsOf: segFile(dir), encoding: .utf8) else { return [] }
        return s.split(separator: "\n").compactMap { l in
            let p = l.split(separator: "\t", omittingEmptySubsequences: false)
            guard p.count >= 3 else { return nil }
            return Segment(startMs: Int64(p[0]) ?? 0, endMs: Int64(p[1]) ?? 0, text: String(p[2]),
                           speaker: p.count > 3 ? Int(p[3]) ?? -1 : -1)
        }
    }

    public static func durationMs(_ dir: URL) -> Int64 {
        let size = (try? FileManager.default.attributesOfItem(atPath: audio(dir).path)[.size] as? NSNumber)?.int64Value ?? 0
        return max(size - 44, 0) / 32
    }

    static func write(_ url: URL, _ s: String) { try? s.write(to: url, atomically: true, encoding: .utf8) }
}

/// Äpi logifail ~/Kirjuta/kirjuta.log (iga tüki pikkus, aeg, RTF).
public enum AppLog {
    private static let lock = NSLock()
    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "MM-dd HH:mm:ss"; return f
    }()
    public static var echo = false

    public static func i(_ tag: String, _ msg: String) {
        lock.lock(); defer { lock.unlock() }
        let line = "\(fmt.string(from: Date())) \(tag): \(msg)\n"
        if echo { FileHandle.standardError.write(Data(line.utf8)) }
        let url = Settings.dataDir.appendingPathComponent("kirjuta.log")
        try? FileManager.default.createDirectory(at: Settings.dataDir, withIntermediateDirectories: true)
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue, size > 2_000_000,
           let data = try? Data(contentsOf: url) {
            try? data.suffix(1_000_000).write(to: url)
        }
        if let fh = try? FileHandle(forWritingTo: url) {
            defer { try? fh.close() }
            _ = try? fh.seekToEnd(); try? fh.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
