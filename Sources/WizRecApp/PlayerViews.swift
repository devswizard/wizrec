import PlayerKit
import SwiftUI

/// Play/pause, frame step, start/end, scrubber and timecode.
struct TransportBar: View {
    static let height: CGFloat = 44
    let engine: PlaybackEngine
    @State private var resumeAfterScrub = false

    var body: some View {
        let grid = engine.grid
        let tb = grid.timebase
        HStack(spacing: 10) {
            button("backward.end.fill", "Go to start (Home)") { engine.goToStart() }
            button("backward.frame.fill", "Previous frame (←)") { engine.step(by: -1) }
            button(engine.isPlaying ? "pause.fill" : "play.fill", "Play/Pause (Space)") { engine.togglePlay() }
                .frame(width: 22)
            button("forward.frame.fill", "Next frame (→)") { engine.step(by: 1) }
            button("forward.end.fill", "Go to end (End)") { engine.goToEnd() }
            Text(tb.timecode(engine.currentTicks))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.primary)
            Slider(
                value: Binding(get: { Double(engine.currentFrame) },
                               set: { engine.seek(toFrame: Int64($0.rounded())) }),
                in: 0...Double(max(1, grid.lastFrame)),
                onEditingChanged: { editing in
                    if editing {
                        resumeAfterScrub = engine.isPlaying
                        engine.pause()
                    } else if resumeAfterScrub {
                        engine.play()
                    }
                }
            )
            .controlSize(.small)
            Text(tb.timecode(grid.duration))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
            Text("\(engine.currentFrame)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .trailing)
                .help("Frame number")
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.bar)
    }

    private func button(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 13)) }
            .buttonStyle(.borderless)
            .help(help)
    }
}

/// Missing-media and compositor banners plus the optional performance overlay.
struct CanvasOverlay: View {
    let engine: PlaybackEngine
    let ui: PlayerUIState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !ui.missing.isEmpty {
                banner(color: .orange, text: missingText)
            }
            if let e = ui.compositorError {
                banner(color: .red, text: "Canvas cannot draw clips: \(e)")
            }
            if ui.showOverlay {
                stats
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private var missingText: String {
        let names = ui.missing.prefix(3).map { ($0.src as NSString).lastPathComponent }
        let more = ui.missing.count > 3 ? " and \(ui.missing.count - 3) more" : ""
        return "\(ui.missing.count) media file\(ui.missing.count == 1 ? " is" : "s are") missing: "
            + names.joined(separator: ", ") + more + ". Playing without them."
    }

    private func banner(color: Color, text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(color.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
    }

    private var stats: some View {
        let s = engine.stats
        func f(_ v: Double, _ d: Int = 1) -> String { String(format: "%.\(d)f", v) }
        let lines = [
            "draw \(f(s.drawFPS)) fps   content \(f(s.contentFPS)) fps (project \(f(engine.grid.fps.double, 2)))",
            "cpu \(f(s.cpuMs, 2)) ms   gpu \(f(s.gpuMs, 2)) ms",
            "dropped \(s.droppedDisplayFrames)   skipped \(s.skippedFrames)   stale \(s.staleDraws)",
            "fetch \(s.fetches)/s   cache≈\(f(s.fastFetchRatio * 100, 0))%   avg \(f(s.fetchMs, 2)) ms",
            "clock \(s.clock)   resyncs \(s.resyncs)   audio underruns \(s.audioUnderruns)" + (engine.lastError.map { "   error: \($0)" } ?? ""),
        ]
        return Text(lines.joined(separator: "\n"))
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.white)
            .padding(8)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
    }
}
