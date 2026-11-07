import SwiftUI

/// Sama palett ja tüpograafia mis Androidi äpis (ui/Theme.kt).
enum K {
    static let bg = Color(hex: 0x07090C)
    static let surface = Color(hex: 0x0E1217)
    static let line = Color(hex: 0x1B222B)
    static let grid = Color(hex: 0x10151B)
    static let text = Color(hex: 0xE6EBF0)
    static let textDim = Color(hex: 0x8893A0)
    static let textFaint = Color(hex: 0x4A5562)
    static let accent = Color(hex: 0x5EE6FF)
    static let rec = Color(hex: 0xFF3347)

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .monospaced) }
    static let label = mono(11)
    static let stamp = mono(11)
    static let body = Font.system(size: 16)
    static let clock = mono(38, .light)

    static let speakerPalette: [Color] = [
        Color(hex: 0x5EE6FF), Color(hex: 0xFFB547), Color(hex: 0xB48CFF), Color(hex: 0x6BE38F), Color(hex: 0xFF7AB8), Color(hex: 0x7AA2FF),
    ]
    static func speaker(_ s: Int) -> Color { speakerPalette[((s % 6) + 6) % 6] }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

extension Text {
    /// Väike suurtähtedega silt (K.label + letterSpacing).
    func label(_ color: Color = K.textDim, size: CGFloat = 11, tracking: CGFloat = 2) -> some View {
        self.font(K.mono(size)).tracking(tracking).foregroundStyle(color)
    }
}

/// Õrn tehniline ruudustik taustal.
struct GridBackground: View {
    var step: CGFloat = 28
    var body: some View {
        Canvas { ctx, size in
            var p = Path()
            var x = step
            while x < size.width { p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)); x += step }
            var y = step
            while y < size.height { p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)); y += step }
            ctx.stroke(p, with: .color(K.grid), lineWidth: 1)
        }
        .background(K.bg)
    }
}

struct HLine: View {
    var body: some View { Rectangle().fill(K.line).frame(height: 1) }
}

/// Vilkumine (0.15…1).
struct Blink: ViewModifier {
    let active: Bool
    var period: Double = 0.65
    @State private var on = false
    func body(content: Content) -> some View {
        content
            .opacity(active ? (on ? 1 : 0.2) : 1)
            .animation(active ? .easeInOut(duration: period).repeatForever(autoreverses: true) : .default, value: on)
            .onAppear { on = active }
            .onChange(of: active) { _, a in on = a }
    }
}

/// Diktofoni punane tuluke.
struct RecLed: View {
    let active: Bool
    var size: CGFloat = 8
    var body: some View {
        ZStack {
            if active {
                Circle().fill(RadialGradient(colors: [K.rec.opacity(0.45), .clear], center: .center, startRadius: 0, endRadius: size * 1.1))
                    .frame(width: size * 2.2, height: size * 2.2)
                    .modifier(Blink(active: true))
            }
            Circle().fill(active ? K.rec : K.textFaint).frame(width: size, height: size)
                .modifier(Blink(active: active))
        }
        .frame(width: size * 2.2, height: size * 2.2)
    }
}

/// Suur salvestusnupp: ring + punane täpp, salvestamise ajal ruut.
struct RecordButton: View {
    let recording: Bool
    let enabled: Bool
    var size: CGFloat = 76
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if recording {
                    Circle().fill(RadialGradient(colors: [K.rec.opacity(0.28), .clear], center: .center, startRadius: 0, endRadius: size * 0.75))
                        .frame(width: size * 1.5, height: size * 1.5)
                        .modifier(Blink(active: true, period: 0.9))
                }
                Circle().strokeBorder(recording ? K.rec.opacity(0.7) : (hover ? K.textFaint : K.line), lineWidth: 1.5)
                    .frame(width: size, height: size)
                let inner = recording ? size * 0.3 : size * 0.66
                RoundedRectangle(cornerRadius: recording ? 6 : inner / 2)
                    .fill(enabled ? K.rec : K.textFaint)
                    .frame(width: inner, height: inner)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .animation(.spring(duration: 0.3), value: recording)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hover = $0 }
    }
}

/// Raamiga tekstinupp nagu Androidi ActionChip.
struct Chip: View {
    let title: String
    var accent = false
    var enabled = true
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text(title).label(accent ? K.accent : K.text, tracking: 1.5)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 10).fill(hover ? K.surface : .clear))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(accent ? K.accent.opacity(0.5) : K.line))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .onHover { hover = $0 }
    }
}

/// Taseme-lainekuju (viimased N taset).
struct Waveform: View {
    let levels: [Float]
    let active: Bool
    var body: some View {
        Canvas { ctx, size in
            let n = levels.count
            let gap: CGFloat = 3
            let w = (size.width - gap * CGFloat(n - 1)) / CGFloat(n)
            let mid = size.height / 2
            for (i, l) in levels.enumerated() {
                let v = active ? CGFloat(l.squareRoot()) * 0.95 + 0.05 : 0.05
                let h = max(size.height * v, 2)
                let a = active ? 0.25 + 0.75 * Double(i) / Double(n) : 1
                let r = CGRect(x: CGFloat(i) * (w + gap), y: mid - h / 2, width: w, height: h)
                ctx.fill(Path(roundedRect: r, cornerRadius: w / 2), with: .color((active ? K.rec : K.line).opacity(a)))
            }
        }
    }
}

/// Teade ekraani allservas (VÕTA TAGASI, „kopeeritud“).
struct Banner<Trailing: View>: View {
    let text: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack {
            Text(text).label(K.text)
            Spacer()
            trailing
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12).fill(K.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(K.line))
        .padding(12)
    }
}
