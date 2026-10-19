import CoreGraphics
import Foundation
import MediaEngine
import Testing
import WizRecAssets
@testable import RenderEngine

// The transitions under test are WizRec's own GLSL (WizRecAssets), not Camtasia content.

private let size = CGSize(width: 192, height: 108)

@Suite struct GLSLTransitionTranslationTests {
    @Test func transitionModeProvidesProgressAndBothInputs() throws {
        let out = try GLSLTranslator.translate("""
        uniform float _Progress;
        uniform float _Number;
        uniform vec3 _Color0;
        void main() { _FragColor = mix(getFromColor(_TexCoord), textureB(_TexCoord), _Progress * _Number); }
        """, mode: .transition)
        #expect(out.uniforms == [.init(name: "_Number", type: "float"), .init(name: "_Color0", type: "vec3")])
        #expect(out.source.contains(GLSLTranslator.Output.transitionFragmentName))
        #expect(!out.source.contains(GLSLTranslator.Output.fragmentName))
    }

    @Test func backgroundModeIsUnchangedByDefault() throws {
        let src = "uniform float _Progress; void main() { _FragColor = vec4(_Progress); }"
        #expect(try GLSLTranslator.translate(src).uniforms == [.init(name: "_Progress", type: "float")])
    }

    @Test func registryCoversTheWholeLibrary() {
        for t in AssetCatalog.transitions {
            #expect(TransitionRegistry.renderers[t.name] != nil, "\(t.name)")
        }
        #expect(TransitionRegistry.renderer("Fade") is FadeTransition)
        #expect(TransitionRegistry.renderer("CubeRotate") is GLSLTransition)
        #expect(TransitionRegistry.renderer("NoSuchTransition") is FadeTransition)
    }

    @Test func parametersMapToUniformSlots() {
        let p = ["Number": 4.0, "Color0-red": 0.5, "Color0-blue": 1]
        #expect(GLSLTransition.value(.init(name: "_Number", type: "float"), p) == SIMD4(4, 0, 0, 0))
        #expect(GLSLTransition.value(.init(name: "_Color0", type: "vec3"), p) == SIMD4(0.5, 0, 1, 1))
        #expect(GLSLTransition.value(.init(name: "_Missing", type: "float"), p) == .zero)
    }
}

@Suite(.enabled(if: hasGPU)) struct GLSLTransitionRenderTests {
    /// A = (255, x, y), B = (0, x, y): both cover the canvas, positions are recognisable.
    private static func frames() -> (FrameRequest, FrameRequest, [FrameRequest: VideoFrame]) {
        let ra = GPUTest.request("ta"), rb = GPUTest.request("tb")
        func pb(_ red: Int) -> VideoFrame {
            GPUTest.frame(GPUTest.pixelBuffer(192, 108) { x, y in Px(r: red, g: x * 255 / 191, b: y * 255 / 107, a: 255) })
        }
        return (ra, rb, [ra: pb(255), rb: pb(0)])
    }

    private static func render(_ name: String, _ p: Double, reverse: Bool = false) throws -> GPUTest.Image {
        let (ra, rb, frames) = Self.frames()
        let a = Layer(clipID: 1, content: .video(ra), size: size)
        let b = Layer(clipID: 2, content: .video(rb), size: size)
        let t = TransitionInstance(name: name, progress: p, duration: 30, reverse: reverse)
        let plan = RenderPlan(time: 0, canvasSize: size, background: RGBA(0, 0, 0),
                              layers: [Layer(clipID: 2, content: .transition(t, from: a, to: b), size: size)])
        return try GPUTest.render(plan, frames: frames)
    }

    private static func plain(_ which: String) throws -> GPUTest.Image {
        let (ra, rb, frames) = Self.frames()
        let l = Layer(clipID: 1, content: .video(which == "a" ? ra : rb), size: size)
        return try GPUTest.render(RenderPlan(time: 0, canvasSize: size, background: RGBA(0, 0, 0), layers: [l]),
                                  frames: frames)
    }

    private static func maxDiff(_ x: GPUTest.Image, _ y: GPUTest.Image) -> Int {
        zip(x.bytes, y.bytes).map { abs(Int($0) - Int($1)) }.max() ?? 0
    }

    @Test(arguments: AssetCatalog.transitions.map(\.name))
    func showsAThenB(name: String) throws {
        let a = try Self.plain("a"), b = try Self.plain("b")
        let start = try Self.render(name, 0), mid = try Self.render(name, 0.5), end = try Self.render(name, 1)
        #expect(Self.maxDiff(start, a) <= 4, "\(name) at 0 is not the outgoing clip")
        #expect(Self.maxDiff(end, b) <= 4, "\(name) at 1 is not the incoming clip")
        #expect(Self.maxDiff(mid, a) > 8 && Self.maxDiff(mid, b) > 8, "\(name) does nothing at 0.5")
    }

    @Test func reverseRunsProgressBackwards() throws {
        let fwd = try Self.render("SlideLeft", 0.3), rev = try Self.render("SlideLeft", 0.7, reverse: true)
        #expect(Self.maxDiff(fwd, rev) <= 1)
    }
}
