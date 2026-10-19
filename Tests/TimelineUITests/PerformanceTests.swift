import AppKit
import Foundation
import Testing
import TimelineEngine
import TSCProjKit
@testable import TimelineUI

@MainActor
struct PerformanceTests {
    /// 280 clips over 4 tracks, 7 minutes, editRate 705600000 at 60 fps (vlog-sized).
    func bigProject() throws -> Project {
        let frame: Int64 = 11_760_000
        let total: Int64 = 420 * 705_600_000
        var tracks: [String] = []
        var id: Int64 = 100
        for t in 0..<4 {
            var medias: [String] = []
            let count = 70
            let slot = total / Int64(count)
            for i in 0..<count {
                let start = (Int64(i) * slot / frame) * frame
                let dur = ((slot * 9 / 10) / frame) * frame
                medias.append(t == 0 ? unified(id, start: start, dur: dur, ms: start)
                              : vm(id, start: start, dur: dur, ms: start, type: t == 3 ? "AMFile" : "VMFile",
                                   src: t == 3 ? 2 : 1))
                id += 1
            }
            tracks.append(trackJSON(t, medias))
        }
        return try makeProject(tracks: "[" + tracks.joined(separator: ", ") + "]",
                               editRate: 705_600_000, fps: 60)
    }

    func time(_ n: Int, _ body: () -> Void) -> Double {
        let t0 = CFAbsoluteTimeGetCurrent()
        for _ in 0..<n { body() }
        return (CFAbsoluteTimeGetCurrent() - t0) / Double(n) * 1000
    }

    @Test func drawAndRebuildStayFast() throws {
        let p = try bigProject()
        let model = TimelineModel(undo: UndoStack(project: p))
        let view = TimelineView(model: model)
        view.frame = CGRect(x: 0, y: 0, width: 1600, height: 420)
        view.mediaProvider = FakeMediaProvider()
        #expect(view.snapshot.allClips.count == 280)

        let rebuild = time(20) { _ = TimelineSnapshot(project: p) }
        let rep = render(view)
        savePNG(rep, "perf-fit")
        let fit = time(10) { view.canvas.cacheDisplay(in: view.bounds, to: rep) }
        model.pointsPerSecond = 200
        view.scrollOffset = CGPoint(x: 20_000, y: 0)
        _ = render(view)
        let zoomed = time(10) { view.canvas.cacheDisplay(in: view.bounds, to: rep) }
        let L = view.currentLayout
        let hit = time(1000) { _ = L.hit(CGPoint(x: 900, y: 200), in: view.snapshot) }
        print(String(format: "TimelineUI perf: rebuild %.2f ms, draw fit %.2f ms, draw zoomed %.2f ms, hit %.4f ms",
                     rebuild, fit, zoomed, hit))
        // Generous bounds for debug builds on CI; the measured numbers go in the REVIEW note.
        #expect(rebuild < 20)
        #expect(fit < 50)
        #expect(zoomed < 50)
        #expect(hit < 0.5)
    }

    /// The user's vlog, read in place (never copied). Skips when absent.
    @Test func userVlogRenders() throws {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Moheshkali Dwip Vlog.cmproj/project.tscproj")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let p = try Project(contentsOf: url)
        let model = TimelineModel(undo: UndoStack(project: p))
        let view = TimelineView(model: model)
        view.frame = CGRect(x: 0, y: 0, width: 1600, height: 360)
        let s = view.snapshot
        #expect(s.tracks.count == 4)
        #expect(s.allClips.count > 70)
        let rebuild = time(10) { _ = TimelineSnapshot(project: p) }
        let rep = render(view)
        savePNG(rep, "vlog-fit")
        let draw = time(10) { view.canvas.cacheDisplay(in: view.bounds, to: rep) }
        print(String(format: "TimelineUI vlog: %d clips, rebuild %.2f ms, draw %.2f ms", s.allClips.count, rebuild, draw))
        #expect(draw < 50)
    }
}
