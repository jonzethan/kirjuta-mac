import AVFoundation
import SwiftUI

/// Lihtne helimängija salvestise jaoks (lõigu klõps -> heli koht).
@MainActor
final class AudioPlayer: ObservableObject {
    @Published private(set) var playing = false
    @Published private(set) var posMs: Int64 = 0
    @Published private(set) var durMs: Int64 = 0
    private var player: AVAudioPlayer?
    static let rates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]
    /// Taasesituse kiirus (helikõrgus jääb samaks); meeles kõigi salvestiste jaoks.
    @Published var rate: Float = {
        let r = UserDefaults.standard.float(forKey: "playbackRate"); return r > 0 ? r : 1
    }() {
        didSet { player?.rate = rate; UserDefaults.standard.set(rate, forKey: "playbackRate") }
    }
    private var url: URL?
    private var timer: Timer?

    func load(_ url: URL?, durationMs: Int64) {
        guard url != self.url else { return }
        stop()
        self.url = url
        player = nil
        posMs = 0
        durMs = durationMs
    }

    private func ensure() -> AVAudioPlayer? {
        if let p = player { return p }
        guard let url, let p = try? AVAudioPlayer(contentsOf: url) else { return nil }
        p.enableRate = true
        p.prepareToPlay()
        p.rate = rate
        durMs = Int64(p.duration * 1000)
        player = p
        return p
    }

    func toggle() {
        guard let p = ensure() else { return }
        if p.isPlaying { p.pause(); setPlaying(false) } else {
            if posMs >= durMs - 200 { p.currentTime = 0 }
            p.play(); setPlaying(true)
        }
    }

    func seek(_ ms: Int64, play: Bool = false) {
        guard let p = ensure() else { return }
        p.currentTime = Double(ms) / 1000
        posMs = ms
        if play && !p.isPlaying { p.play(); setPlaying(true) }
    }

    func stop() {
        player?.stop()
        setPlaying(false)
    }

    private func setPlaying(_ on: Bool) {
        playing = on
        timer?.invalidate(); timer = nil
        if on {
            timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let p = self.player else { return }
                    self.posMs = Int64(p.currentTime * 1000)
                    if !p.isPlaying { self.playing = false; self.timer?.invalidate(); self.timer = nil; self.posMs = self.durMs }
                }
            }
        }
    }
}

extension AudioPlayer {
    static func label(_ r: Float) -> String {
        (r == r.rounded() ? String(format: "%.0f", r) : String(format: "%g", r)).replacingOccurrences(of: ".", with: ",") + "×"
    }
}

struct PlayerBar: View {
    @ObservedObject var player: AudioPlayer
    @State private var dragging: Double?

    var body: some View {
        HStack(spacing: 12) {
            Button(action: player.toggle) {
                ZStack {
                    Circle().strokeBorder(K.accent.opacity(0.6))
                    Image(systemName: player.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 13)).foregroundStyle(K.accent)
                        .offset(x: player.playing ? 0 : 1)
                }
                .frame(width: 38, height: 38)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
            Text(formatClock(player.posMs)).font(K.stamp).foregroundStyle(K.text)
            Slider(value: Binding(
                get: { dragging ?? (player.durMs > 0 ? Double(player.posMs) / Double(player.durMs) : 0) },
                set: { dragging = $0 }
            ), onEditingChanged: { editing in
                if !editing, let d = dragging { player.seek(Int64(d * Double(player.durMs))); dragging = nil }
            })
            .tint(K.accent)
            Text(formatClock(player.durMs)).font(K.stamp).foregroundStyle(K.textFaint)
            Menu {
                ForEach(AudioPlayer.rates, id: \.self) { r in
                    Button { player.rate = r } label: {
                        Text((r == player.rate ? "✓ " : "   ") + AudioPlayer.label(r))
                    }
                }
            } label: {
                Text(AudioPlayer.label(player.rate)).label(player.rate == 1 ? K.textDim : K.accent, tracking: 1)
            }
            .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(player.rate == 1 ? K.line : K.accent.opacity(0.5)))
            .fixedSize()
            .help("Taasesituse kiirus")
        }
    }
}

import KirjutaCore
