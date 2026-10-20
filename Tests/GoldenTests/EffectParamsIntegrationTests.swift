import CoreGraphics
import Foundation
import MediaEngine
import Metal
import RenderEngine
import Testing
import TestGenKit
import TimelineEngine
import TSCProjKit

// S5-QA-1 / render6 slice 2: Border, Reflection (incl. catalog defaults for an effect saved
// without parameters), and the rotation0 tilt / shear0 skew, end to end: a generated project →
// AddEffect through an undo stack → OfflineRenderer → save → reopen (lossless) → same pixels.
// Geometry checks follow the [WizRec]/[inf] conventions in RenderEngine (Border width and
// Reflection distance in canvas px, Reflection fade over half the layer height, orthographic
// tilt, shear in degrees); they pin today's behaviour until the EF8/EF9 references exist.

private let W = 1280, H = 720
/// The red still: 200 × 100 px.
private let imgW = 200, imgH = 100

/// Canvas pixel (top-left origin) of canvas point (x, y) given in px from the centre, +y up.
private func px(_ x: Double, _ y: Double) -> (Int, Int) { (Int(Double(W) / 2 + x), Int(Double(H) / 2 - y)) }

@MainActor
private func buildProject(in dir: URL) throws -> (ProjectBundle, clips: [String: Int64]) {
    let fm = FileManager.default
    let bundleURL = dir.appendingPathComponent("fx.cmproj", isDirectory: true)
    let media = bundleURL.appendingPathComponent("media/1", isDirectory: true)
    try fm.createDirectory(at: media, withIntermediateDirectories: true)
    try MediaWriter.writePNG(to: media.appendingPathComponent("red.png"), width: imgW, height: imgH) { ctx in
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: imgW, height: imgH))
    }
    let b = ProjectBuilder(title: "fx", width: W, height: H)
    let src = b.addImageSource(src: "./media/1/red.png", width: imgW, height: imgH,
                               modified: Date(timeIntervalSince1970: 1_792_000_000))
    let layout: [(String, Double, Double, [String: ParamSpec])] = [
        ("border", -400, 150, [:]),
        ("borderDefaults", 0, 150, [:]),
        ("reflection", 400, 150, [:]),
        ("tilt", -400, -150, ["rotation0": .constant(Double.pi / 3)]),
        ("shear", 0, -150, ["shear0": .constant(30)]),
    ]
    var ids: [String: Int64] = [:]
    for (name, x, y, extra) in layout {
        var params = extra
        params["translation0"] = .constant(x)
        params["translation1"] = .constant(y)
        let clip = b.image(src, start: 0, duration: b.frames(30), params: params)
        ids[name] = clip["id"]?.int
        b.tracks.append([clip])
    }
    try b.build().serialized().write(to: bundleURL.appendingPathComponent("project.tscproj"), options: .atomic)
    return (try ProjectBundle(url: bundleURL), ids)
}

@MainActor
private func render(_ bundle: ProjectBundle) async throws -> RGBAImage {
    let r = OfflineRenderer(scene: SceneModel(project: bundle.project, resolve: bundle.resolve),
                            pool: MediaPool(diskCacheDirectory: nil))
    return RGBAImage(try await r.image(at: frames(10), size: CGSize(width: W, height: H)))
}

@Suite(.serialized, .enabled(if: MTLCreateSystemDefaultDevice() != nil, "needs a Metal device"))
@MainActor struct EffectParamsIntegrationTests {
    @Test func borderReflectionTiltShearThroughProject() async throws {
        let dir = try scratchDir("s5-fx-params")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (bundle, ids) = try buildProject(in: dir)
        let chain = EditChain(bundle.project)
        try chain.run(AddEffect(clipID: try #require(ids["border"]), effectJSON: EffectJSON.string(EffectJSON.make("Border", [
            ("enabled", .int(1)), ("color-red", .double(0)), ("color-green", .double(1)), ("color-blue", .double(0)),
            ("color-alpha", .double(1)), ("width", .double(8)), ("type", .int(0)),
        ]))))
        // No parameters at all: the catalog defaults (on, opaque white, width 1) apply.
        try chain.run(AddEffect(clipID: try #require(ids["borderDefaults"]), effectJSON: EffectJSON.string(EffectJSON.make("Border", []))))
        try chain.run(AddEffect(clipID: try #require(ids["reflection"]), effectJSON: EffectJSON.string(EffectJSON.make("Reflection", [
            ("distance", .double(10)), ("opacity", .double(0.5)),
        ]))))
        try chain.expectUndoRedoWalk()

        let img = try await render(bundle)
        func at(_ p: (Int, Int)) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) { img.pixel(p.0, p.1) }
        func isRed(_ c: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool { c.r > 230 && c.g < 25 && c.b < 25 }
        func isBlack(_ c: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool { c.r < 25 && c.g < 25 && c.b < 25 }

        // Border: 8 canvas px of green outside the right edge (x = -300 from centre), then background.
        #expect(isRed(at(px(-305, 150))), "border clip interior \(at(px(-305, 150)))")
        let green = at(px(-296, 150))
        #expect(green.g > 230 && green.r < 25 && green.b < 25, "inside the 8 px border: \(green)")
        #expect(isBlack(at(px(-288, 150))), "past the border: \(at(px(-288, 150)))")
        // Square outside corner [WizRec]: the diagonal just off the corner is filled.
        let corner = at(px(-296, 150 + Double(imgH) / 2 + 4))
        #expect(corner.g > 230, "border corner \(corner)")

        // Defaults: a 1 px white ring just outside the left edge (x = -100).
        let ring = at((W / 2 - 101, H / 2 - 150))
        #expect(ring.r > 200 && ring.g > 200 && ring.b > 200, "default 1 px white border: \(ring)")
        #expect(isBlack(at((W / 2 - 104, H / 2 - 150))), "default border wider than 1 px")

        // Reflection: gap of 10 px under the bottom edge (y = 100), then the mirrored red at about
        // half strength fading out over 50 px.
        let bottom = 150.0 - Double(imgH) / 2
        #expect(isBlack(at(px(400, bottom - 5))), "reflection gap \(at(px(400, bottom - 5)))")
        let near = at(px(400, bottom - 12))
        #expect(near.r > 100 && near.r < 135 && near.g < 20, "reflection start ≈ 0.5 × red: \(near)")
        let far = at(px(400, bottom - 50))
        #expect(far.r < near.r && far.r > 20, "reflection fades: \(far) vs \(near)")
        #expect(isBlack(at(px(400, bottom - 70))), "reflection past its fade: \(at(px(400, bottom - 70)))")

        // Tilt rotation0 = π/3: height × cos = 50 px (y −175…−125), width unchanged.
        #expect(isRed(at(px(-400, -150))) && isRed(at(px(-400, -129))), "tilted clip interior")
        #expect(isBlack(at(px(-400, -120))) && isBlack(at(px(-400, -180))), "tilt did not shorten the clip")
        #expect(isRed(at(px(-305, -150))), "tilt changed the width")

        // Shear 30°: x += tan 30° · y; the right edge moves +26 px at y = +45, −26 px at y = −45.
        #expect(isRed(at(px(120, -150 + 45))), "sheared top row should reach x ≈ 126")
        #expect(isBlack(at(px(120, -150 - 45))), "sheared bottom row should end at x ≈ 74")

        // Save → reopen: byte-identical project and pixels.
        try bundle.saveWithBackup()
        let reopened = try ProjectBundle(url: bundle.directory)
        #expect(reopened.project.serialized() == chain.project.serialized())
        #expect(ProjectInvariants.check(reopened.project).isEmpty)
        let again = try await render(reopened)
        #expect(again == img, "render after reopen differs")

        // Undo all three effects: the clips render without border or reflection.
        try chain.undoAll()
        let plain = try await render(bundle)
        #expect(isBlack(plain.pixel(px(-296, 150).0, px(-296, 150).1)), "border survived undo")
        #expect(isBlack(plain.pixel(px(400, bottom - 12).0, px(400, bottom - 12).1)), "reflection survived undo")
    }
}
