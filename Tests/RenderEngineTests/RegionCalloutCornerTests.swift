import CoreGraphics
import Foundation
import MediaEngine
import Testing
import TSCProjKit
@testable import RenderEngine

// Rounded corners of region callouts (`corner-radius`, callouts.md §3.1 CO3): blur, pixelate, spotlight and the
// inverted forms, where the rounded box is the hole.

private let canvas = CGSize(width: 192, height: 108)

/// 1-px vertical black/white stripes over the whole canvas: blur turns them grey, pixelate makes runs.
private let stripes = GPUTest.request("corner-stripes")
private let stripeFrame = GPUTest.frame(GPUTest.pixelBuffer(192, 108) { x, _ in x % 2 == 0 ? .black : .white })
private let white = GPUTest.request("corner-white")
private let whiteFrame = GPUTest.frame(GPUTest.pixelBuffer(16, 16) { _, _ in .white })

/// An 80×40 region box centred on the canvas: x 56…136, y 34…74 (target px, y down).
private func region(_ kind: String, radius: Double, intensity: Double = 1, invert: Bool = false) -> Layer {
    var c = CalloutContent(kind: kind, shape: "", size: CGSize(width: 80, height: 40), cornerRadius: radius,
                           intensity: intensity)
    c.invert = invert
    return Layer(clipID: 2, content: .callout(c), size: c.size)
}

private func render(_ top: Layer, over base: FrameRequest = stripes) throws -> GPUTest.Image {
    let frame = base == stripes ? stripeFrame : whiteFrame
    let bg = Layer(clipID: 1, content: .video(base), size: canvas)
    return try GPUTest.render(RenderPlan(time: 0, canvasSize: canvas, background: RGBA(0, 0, 0), layers: [bg, top]),
                              frames: [base: frame])
}

private extension Px {
    var isStripe: Bool { self == .black || self == .white }
    var isGrey: Bool { r > 60 && r < 195 && r == g && g == b }
}

/// Pixels just inside each corner of the box (outside a 12 px rounded corner) and at each edge's middle.
private let corners = [(57, 35), (134, 35), (57, 72), (134, 72)]
private let edges = [(96, 35), (57, 54), (134, 54), (96, 72)]

@Suite(.enabled(if: hasGPU)) struct RegionCalloutCornerTests {
    @Test func blurCornersAreRounded() throws {
        let img = try render(region("TypeWinBlur", radius: 12))
        for (x, y) in corners { #expect(img.at(x, y).isStripe, "corner \(x),\(y)") }   // outside the rounding: untouched
        for (x, y) in edges { #expect(img.at(x, y).isGrey, "edge \(x),\(y)") }
        #expect(img.at(96, 54).isGrey && img.at(20, 54).isStripe)
        let square = try render(region("TypeWinBlur", radius: 0))
        for (x, y) in corners + [(56, 34), (135, 73)] { #expect(square.at(x, y).isGrey, "square \(x),\(y)") }
    }

    @Test func invertedBlurHasARoundedHole() throws {
        let img = try render(region("TypeWinBlur", radius: 12, invert: true))
        for (x, y) in corners { #expect(img.at(x, y).isGrey, "corner \(x),\(y)") }       // the hole's corners blur
        for (x, y) in edges { #expect(img.at(x, y).isStripe, "edge \(x),\(y)") }
        #expect(img.at(96, 54).isStripe && img.at(20, 54).isGrey)
        let square = try render(region("TypeWinBlur", radius: 0, invert: true))
        for (x, y) in corners + [(56, 34), (135, 73)] { #expect(square.at(x, y).isStripe, "square \(x),\(y)") }
    }

    @Test func pixelateCornersAreRounded() throws {
        // intensity 0.2 → 12-px blocks on a 12-px grid: in a block, neighbours match; stripes alternate.
        let img = try render(region("TypeWinPixelate", radius: 12, intensity: 0.2))
        for (x, y) in corners { #expect(img.at(x, y) != img.at(x + 1, y), "corner \(x),\(y)") }
        #expect(img.at(97, 35) == img.at(98, 35) && img.at(97, 72) == img.at(98, 72))
        let square = try render(region("TypeWinPixelate", radius: 0, intensity: 0.2))
        for (x, y) in corners { #expect(square.at(x, y) == square.at(x + 1, y), "square \(x),\(y)") }
    }

    @Test func spotlightHoleIsRounded() throws {
        let dim = Px(r: 128, g: 128, b: 128, a: 255)
        let img = try render(region("TypeWinSpotlight", radius: 12, intensity: 0.5), over: white)
        for (x, y) in corners { #expect(img.at(x, y).near(dim, 2), "corner \(x),\(y)") }
        for (x, y) in edges { #expect(img.at(x, y) == .white, "edge \(x),\(y)") }
        #expect(img.at(10, 10).near(dim, 2))
        let square = try render(region("TypeWinSpotlight", radius: 0, intensity: 0.5), over: white)
        for (x, y) in corners + [(56, 34), (135, 73)] { #expect(square.at(x, y) == .white, "square \(x),\(y)") }
        #expect(square.at(55, 34).near(dim, 2) && square.at(56, 33).near(dim, 2))
    }

    @Test func invertedHighlighterHoleIsRounded() throws {
        var c = CalloutContent(kind: "TypeWinHighlighter", shape: "", size: CGSize(width: 80, height: 40),
                               fill: RGBA(1, 0, 1, 0.5), cornerRadius: 12)
        c.invert = true
        let img = try render(Layer(clipID: 2, content: .callout(c), size: c.size), over: white)
        let tint = Px(r: 255, g: 128, b: 255, a: 255)
        for (x, y) in corners { #expect(img.at(x, y).near(tint, 2), "corner \(x),\(y)") }
        for (x, y) in edges { #expect(img.at(x, y) == .white, "edge \(x),\(y)") }
    }

    @Test func radiusScalesWithTheCalloutAndClampsToTheBox() throws {
        // At scale 0.5 a 24 px radius is 12 target px: same corners as above.
        var half = region("TypeWinBlur", radius: 24)
        half.size = CGSize(width: 160, height: 80)
        if case .callout(var c) = half.content { c.size = half.size; half.content = .callout(c) }
        half.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
        let img = try render(half)
        for (x, y) in corners { #expect(img.at(x, y).isStripe, "corner \(x),\(y)") }
        for (x, y) in edges { #expect(img.at(x, y).isGrey, "edge \(x),\(y)") }
        // A radius larger than half the short side is a full pill (radius 20): edge middles still covered.
        let pill = try render(region("TypeWinBlur", radius: 1000))
        #expect(pill.at(57, 54).isGrey && pill.at(96, 35).isGrey && pill.at(60, 38).isStripe)
    }

    @Test func deterministic() throws {
        for kind in ["TypeWinBlur", "TypeWinPixelate", "TypeWinSpotlight"] {
            let a = try render(region(kind, radius: 6, intensity: 0.5, invert: kind == "TypeWinBlur"))
            let b = try render(region(kind, radius: 6, intensity: 0.5, invert: kind == "TypeWinBlur"))
            #expect(a.bytes == b.bytes, "\(kind)")
        }
    }

    /// The radius comes from the project's `corner-radius`; save and reopen renders the same pixels.
    @Test func projectCornerRadiusSurvivesSaveAndReopen() throws {
        let s = P.rate
        func project(_ def: [String: Any]) throws -> Project {
            let clip = P.clip("Callout", id: 60, start: 0, duration: 5 * s, extra: ["def": def])
            return try P.project(tracks: [P.track(0, [clip])], width: 192, height: 108)
        }
        func draw(_ p: Project) throws -> GPUTest.Image {
            var plan = P.scene(p).evaluate(at: 0)
            plan.background = RGBA(1, 1, 1)
            return try GPUTest.render(plan)
        }
        let def: [String: Any] = ["kind": "TypeWinSpotlight", "shape": "", "style": "", "width": 80.0, "height": 40.0,
                                  "intensity": 0.5, "corner-radius": 12.0]
        let original = try project(def)
        let img = try draw(original)
        let dim = Px(r: 128, g: 128, b: 128, a: 255)
        for (x, y) in corners { #expect(img.at(x, y).near(dim, 2), "corner \(x),\(y)") }
        for (x, y) in edges { #expect(img.at(x, y) == .white, "edge \(x),\(y)") }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wz-corner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("p.tscproj")
        try original.serialized().write(to: url)
        let reopened = try Project(contentsOf: url)
        #expect(reopened.serialized() == original.serialized())
        #expect(try draw(reopened).bytes == img.bytes)

        // No `corner-radius` key: square, as before.
        var plain = def
        plain["corner-radius"] = nil
        let square = try draw(try project(plain))
        for (x, y) in corners { #expect(square.at(x, y) == .white, "square \(x),\(y)") }
    }
}
