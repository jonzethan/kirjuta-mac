import Foundation

/// Whisperi tüüpiliste vigade koristus (port Androidi Engine.kt TextCleaner-ist):
/// korduvad laused, võõras tähestik, vaikuse-„Aitäh“.
public enum TextCleaner {
    static let silencePhrases: Set<String> = [
        "aitäh", "tänan", "aitäh vaatamast", "aitäh kuulamast", "tänan tähelepanu eest",
        "thank you", "thanks for watching", "thank you for watching", "you", "bye",
    ]
    private static let nonLatinLetter = try! NSRegularExpression(pattern: "[\\p{L}&&[^\\p{Latin}]]")
    private static let sentenceSplit = try! NSRegularExpression(pattern: "(?<=[.!?…])\\s+")
    private static let nonWord = try! NSRegularExpression(pattern: "[^\\p{L}\\p{N} ]")
    private static let spaces = try! NSRegularExpression(pattern: "\\s+")
    private static let hyphenRepeat = try! NSRegularExpression(pattern: "\\b([\\p{L}\\p{N}]+)(?:-\\1\\b){2,}", options: [.caseInsensitive])

    public static func clean(_ text: String) -> String {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "" }
        // 0) „Bat-Bat-Bat-…“ -> „Bat“ (kordamine ühe sõna sees)
        let text = replace(text, hyphenRepeat, "$1")
        // 1) sõnad võõra tähestikuga (kirillitsa, hangul jne) välja
        let words = split(text, spaces).filter { !matches(nonLatinLetter, $0) }
        var t = words.joined(separator: " ")
        // 2) korduvad laused: jäta iga lause alles ainult esimest korda
        var seen = Set<String>()
        var kept: [String] = []
        for s in split(t, sentenceSplit) {
            let key = norm(s)
            if key.isEmpty { continue }
            if seen.insert(key).inserted { kept.append(s) }
        }
        t = kept.joined(separator: " ")
        // 3) sama 1–6-sõnaline fraas järjest ≥3 korda
        t = collapseRepeats(t)
        // 4) kogu tükk on ainult vaikuse-fraas
        if silencePhrases.contains(norm(t)) { return "" }
        return t.trimmingCharacters(in: .whitespaces)
    }

    static func norm(_ s: String) -> String {
        var r = replace(s.lowercased(), nonWord, "")
        r = r.trimmingCharacters(in: .whitespaces)
        return replace(r, spaces, " ")
    }

    private static func collapseRepeats(_ t: String) -> String {
        var w = t.split(separator: " ").map(String.init)
        for n in 1...6 {
            var i = 0
            while i + 2 * n <= w.count {
                var reps = 1
                while i + (reps + 1) * n <= w.count,
                      (0..<n).allSatisfy({ k in norm(w[i + k]) == norm(w[i + reps * n + k]) }) {
                    reps += 1
                }
                if reps >= 3 { w.removeSubrange((i + n)..<(i + n + (reps - 1) * n)) }
                i += 1
            }
        }
        return w.joined(separator: " ")
    }

    // --- NSRegularExpression abi ---
    private static func ns(_ s: String) -> NSRange { NSRange(s.startIndex..., in: s) }
    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: ns(s)) != nil
    }
    private static func replace(_ s: String, _ re: NSRegularExpression, _ with: String) -> String {
        re.stringByReplacingMatches(in: s, range: ns(s), withTemplate: with)
    }
    private static func split(_ s: String, _ re: NSRegularExpression) -> [String] {
        var out: [String] = []
        var last = s.startIndex
        for m in re.matches(in: s, range: ns(s)) {
            guard let r = Range(m.range, in: s) else { continue }
            out.append(String(s[last..<r.lowerBound])); last = r.upperBound
        }
        out.append(String(s[last...]))
        return out.filter { !$0.isEmpty }
    }
}
