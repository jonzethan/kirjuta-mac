import AVFoundation
import SwiftUI

/// Lihtne helimängija salvestise jaoks (lõigu klõps -> heli koht).
@MainActor
final class AudioPlayer: ObservableObject {
    @Published private(set) var playing = false
    @Published private(set) var posMs: Int64 = 0
    @Published private(set) var durMs: Int64 = 0
    private var player: AVAudioPlayer?
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
        p.prepareToPlay()
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
        }
    }
}

import KirjutaCore
