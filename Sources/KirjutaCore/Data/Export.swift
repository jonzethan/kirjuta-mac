import Foundation

/// Ekspordivormingud: TXT (ajatemplitega / ilma), Markdown, SRT, VTT.
public enum Export {
    public enum Format: String, CaseIterable, Identifiable, Sendable {
        case txt, txtPlain, md, srt, vtt
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .txt: return "Tekst ajatemplitega (.txt)"
            case .txtPlain: return "Tekst ilma ajatempliteta (.txt)"
            case .md: return "Markdown (.md)"
            case .srt: return "Subtiitrid SRT (.srt)"
            case .vtt: return "Subtiitrid WebVTT (.vtt)"
            }
        }
        public var ext: String {
            switch self { case .txt, .txtPlain: return "txt"; case .md: return "md"; case .srt: return "srt"; case .vtt: return "vtt" }
        }
    }

    static let displayFormat: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "et_EE"); f.dateFormat = "dd.MM.yyyy HH:mm"; return f
    }()

    public static func displayTitle(_ dir: URL) -> String {
        Sessions.title(dir) ?? Sessions.startedAt(dir).map { displayFormat.string(from: $0) } ?? dir.lastPathComponent
    }

    public static func render(_ f: Format, dir: URL, segs: [Segment]) -> String {
        switch f {
        case .txt: return plainText(dir, segs, withTimes: true)
        case .txtPlain: return plainText(dir, segs, withTimes: false)
        case .md: return markdown(dir, segs)
        case .srt: return subtitles(dir, segs, vtt: false)
        case .vtt: return subtitles(dir, segs, vtt: true)
        }
    }

    /// Sama mis Androidi Sessions.plainText: kõneleja vahetus = uus lõik.
    public static func plainText(_ dir: URL, _ segs: [Segment], withTimes: Bool = true) -> String {
        let names = Sessions.speakerNames(dir)
        var out = "Kirjuta · \(displayTitle(dir)) · kestus \(formatClock(Sessions.durationMs(dir)))\n\n"
        var last = -2
        for s in segs {
            if s.speaker >= 0 {
                if s.speaker != last {
                    if last != -2 { out += "\n" }
                    if withTimes { out += "[\(formatClock(s.startMs))] " }
                    out += Sessions.speakerName(names, s.speaker) + ": "
                } else { out += " " }
                out += s.text
                last = s.speaker
            } else {
                if withTimes { out += "[\(formatClock(s.startMs))] " }
                out += s.text + "\n"
            }
        }
        if last >= 0 { out += "\n" }
        return out
    }

    public static func markdown(_ dir: URL, _ segs: [Segment]) -> String {
        let names = Sessions.speakerNames(dir)
        var out = "# \(displayTitle(dir))\n\n*Kirjuta · kestus \(formatClock(Sessions.durationMs(dir))) · \(Sessions.lang(dir) == "en" ? "inglise" : "eesti") keel*\n\n"
        var last = -2
        for s in segs {
            if s.speaker >= 0 && s.speaker == last { out.removeLast(); out += " \(s.text)\n"; continue }
            out += "\n`\(formatClock(s.startMs))` "
            if s.speaker >= 0 { out += "**\(Sessions.speakerName(names, s.speaker)):** " }
            out += s.text + "\n"
            last = s.speaker
        }
        return out
    }

    public static func subtitles(_ dir: URL, _ segs: [Segment], vtt: Bool) -> String {
        let names = Sessions.speakerNames(dir)
        func ts(_ ms: Int64) -> String {
            String(format: "%02lld:%02lld:%02lld%@%03lld", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, vtt ? "." : ",", ms % 1000)
        }
        var out = vtt ? "WEBVTT\n\n" : ""
        for (i, s) in segs.enumerated() {
            if !vtt { out += "\(i + 1)\n" }
            let end = max(s.endMs, s.startMs + 500)
            out += "\(ts(s.startMs)) --> \(ts(end))\n"
            if s.speaker >= 0 {
                let n = Sessions.speakerName(names, s.speaker)
                out += vtt ? "<v \(n)>\(s.text)\n\n" : "\(n): \(s.text)\n\n"
            } else { out += s.text + "\n\n" }
        }
        return out
    }
}
