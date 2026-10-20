import Foundation
import ImageIO
import TestGenKit
import Testing
import TSCProjKit

/// A fresh temporary directory per call.
func scratchDir(_ name: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("wizrec-qa-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite struct MediaRoundTripTests {
    /// Frame n of a synthesised movie decodes back to barcode n, and frame extraction is exact.
    @Test func writtenFramesReadBackByIndex() async throws {
        let dir = try scratchDir("media")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("card.mp4")
        let card = TestCard(width: 480, height: 270, label: "T")
        let movie = try MediaWriter.writeH264(to: url, width: 480, height: 270, fps: 30, frameCount: 60) { n, ctx in
            card.draw(frame: n, fps: 30, in: ctx)
        }
        #expect(movie.timescale == 30000)

        let info = try await MovieFrameReader.info(url)
        #expect(info.width == 480 && info.height == 270)
        #expect(abs(info.fps - 30) < 0.01)
        #expect(abs(info.duration - 2) < 1e-6)

        let frames = try await MovieFrameReader.frames(url, indices: [0, 1, 29, 30, 59])
        for (n, img) in frames {
            #expect(card.decodeFrameNumber(img) == n, "frame \(n)")
        }
        await #expect(throws: MovieReadError.self) {
            _ = try await MovieFrameReader.frames(url, indices: [60])
        }
    }

    @Test func barcodeRoundTripsWithoutCompression() throws {
        let card = TestCard(width: 320, height: 180, label: "A")
        for n in [0, 1, 2, 255, 4095, 65535] {
            var img: RGBAImage?
            let dir = try scratchDir("png")
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("f.png")
            try MediaWriter.writePNG(to: url, width: 320, height: 180) { card.draw(frame: n, fps: 30, in: $0) }
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
               let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) { img = RGBAImage(cg) }
            let decoded = try #require(img)
            #expect(card.decodeFrameNumber(decoded) == n)
        }
        // A flat image has no guard pattern.
        #expect(card.decodeFrameNumber(RGBAImage(width: 320, height: 180, fill: (128, 128, 128))) == nil)
    }
}

/// Builds every case with small media and checks the projects are well-formed.
@Suite(.serialized) struct GeneratorTests {
    static let editRate: Int64 = 705_600_000
    static let frameTicks: Int64 = editRate / 30

    @Test func casesHaveUniqueNamesAndSaneFrames() {
        let names = TestGen.cases.map(\.name)
        #expect(Set(names).count == names.count)
        for c in TestGen.cases {
            #expect(!c.frames.isEmpty, "\(c.name)")
            #expect(c.frames.allSatisfy { $0 >= 0 && $0 < c.durationFrames }, "\(c.name)")
            #expect(c.sourceFrames.keys.allSatisfy { $0 < c.durationFrames }, "\(c.name)")
        }
    }

    @Test func generatedProjectsAreWellFormed() throws {
        let out = try scratchDir("gen")
        defer { try? FileManager.default.removeItem(at: out) }
        let media = try TestGen.makeMedia(in: out.appendingPathComponent("_media"), scale: 0.1)

        for c in TestGen.cases {
            let caseDir = try TestGen.write(c, media: media, to: out)
            let manifest = try GoldenManifest.load(caseDir.appendingPathComponent("golden.json"))
            #expect(manifest.caseName == c.name)
            #expect(manifest.frames == c.frames)
            #expect(manifest.ssimMin == 0.97)

            let bundle = try ProjectBundle(url: caseDir.appendingPathComponent(manifest.project))
            let p = bundle.project
            #expect(bundle.missingMedia().isEmpty, "\(c.name)")
            #expect(p.formatVersion == "10.0")
            #expect(p.timebase.editRate == Self.editRate)
            #expect(p.frameRate == Rational(30))
            #expect(p.width == 1920 && p.height == 1080)
            #expect(p.duration == Int64(c.durationFrames) * Self.frameTicks, "\(c.name) duration")
            #expect(p.timeline?.trackAttributes.count == p.tracks.count)

            // Serialising is a fixed point (the file is exactly what TSCProjKit writes).
            let data = try Data(contentsOf: bundle.projectFile)
            #expect(try Project(data: data).serialized() == data, "\(c.name)")

            // Ids unique across the document; clip ids above every source id.
            var ids: [Int64] = []
            func collect(_ v: JSON) {
                if let o = v.object {
                    if let id = o["id"]?.int { ids.append(id) }
                    o.entries.forEach { collect($0.value) }
                } else if let a = v.array { a.items.forEach(collect) }
            }
            collect(.object(p.root))
            #expect(Set(ids).count == ids.count, "\(c.name) duplicate ids \(ids)")
            let maxSource = p.sourceBin.map(\.id).max() ?? 0

            for track in p.tracks {
                for top in track.clips {
                    top.walk { clip, _ in Self.checkClip(clip, in: p, case: c.name, maxSource: maxSource) }
                }
            }
            // Video sources describe the generated files.
            for s in p.sourceBin {
                let url = bundle.resolve(s)
                if url.pathExtension == "mp4" {
                    let movie = try #require(media.movies.values.first { s.rect == [0, 0, Double($0.width), Double($0.height)] })
                    let track = try #require(s.tracks.first)
                    #expect(track.isVideo)
                    #expect(track.editRate == Int64(movie.timescale))
                    #expect(abs(track.durationSeconds - Double(movie.frameCount) / 30) < 1e-9)
                } else {
                    #expect(s.tracks.first?.type == 1)
                }
            }
        }
    }

    /// Per-clip invariants of a generated project (split out of `generatedProjectsAreWellFormed`
    /// to keep the closure cheap to type-check).
    private static func checkClip(_ clip: Clip, in p: Project, case name: String, maxSource: Int64) {
        #expect(clip.id > maxSource)
        // Camtasia's speed relation: mediaDuration × scalar = duration
        // (images: mediaStart 0, mediaDuration 1 tick, whatever the duration).
        if clip.kind == .image {
            #expect(clip.mediaDuration == Rational(1) && clip.mediaStart == Rational(0))
        } else {
            #expect(clip.mediaDuration * clip.scalar == Rational(clip.duration), "\(name) clip \(clip.id)")
        }
        // Whole output frames (allowSubFrameEditing false).
        #expect(clip.start % Self.frameTicks == 0 && clip.duration % Self.frameTicks == 0)
        #expect(clip.mediaStart.den == 1 && clip.mediaStart.num % Self.frameTicks == 0)
        if let src = clip.sourceID { #expect(p.source(id: src) != nil, "\(name) src \(src)") }
        if clip.kind == .stitched {
            var t: Int64 = 0
            for seg in clip.segments { #expect(seg.start == t); t = seg.end }
            #expect(clip.mediaStart.double + clip.mediaDuration.double <= Double(t))
        }
        // Keyframe windows are mirrored in animationTracks.visual.
        let windows: Set<[Int64]> = Set(clip.visualAnimations.compactMap { (v: JSONObject) -> [Int64]? in
            guard let r: [Int64] = v["range"]?.array?.items.compactMap(\.int), r.count == 2 else { return nil }
            return [r[0], r[0] + r[1]]
        })
        for param in clip.parameters.names {
            for k in clip.parameters[param]?.keyframes ?? [] {
                let window: [Int64] = [k.time, k.endTime]
                #expect(windows.contains(window), "\(name) \(param)")
                #expect(k.endTime - k.time == k.duration)
            }
        }
    }

    /// Spot checks of the JSON Camtasia will read, for the cases with special keys.
    @Test func speedAndGroupKeys() throws {
        let out = try scratchDir("keys")
        defer { try? FileManager.default.removeItem(at: out) }
        let media = try TestGen.makeMedia(in: out.appendingPathComponent("_media"), scale: 0.1)
        func project(_ name: String) throws -> Project {
            let c = try #require(TestGen.cases.first { $0.name == name })
            let dir = try TestGen.write(c, media: media, to: out)
            return try ProjectBundle(url: dir.appendingPathComponent("\(name).cmproj")).project
        }
        let fast = try #require(try project("speed-2x").tracks.first?.clips.first)
        #expect(fast.scalar == Rational(1, 2))
        #expect(fast.object["scalar"]?.string == "1/2")
        #expect(fast.mediaDuration == Rational(240 * Self.frameTicks))
        #expect(fast.metadata?["effectApplied"]?.string == "Clip Speed")
        // Media time at timeline frame 1 is source frame 32 (2× from frame 30).
        #expect(fast.mediaTime(atTimeline: Self.frameTicks) == Rational(32 * Self.frameTicks))

        let group = try #require(try project("group-offset").tracks.first?.clips.first)
        #expect(group.kind == .group)
        #expect(group.tracks.count == 2)
        #expect(group.attributes?["widthAttr"]?.double == 1920)
        #expect(group.tracks.allSatisfy { $0.object["videoHidden"]?.bool == false })
        #expect(group.id < group.tracks[0].clips[0].id)
    }
}
