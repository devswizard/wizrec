import CoreGraphics
import CoreText
import CryptoKit
import Foundation
import Testing
import WizRecAssets
@testable import RenderEngine

@Suite struct CatalogTests {
    @Test func identifiersAreUniqueAndListsNonEmpty() {
        func unique(_ ids: [String]) -> Bool { Set(ids).count == ids.count && !ids.isEmpty }
        #expect(unique(AssetCatalog.transitions.map(\.name)))
        #expect(unique(AssetCatalog.backgrounds.map(\.id)))
        #expect(unique(AssetCatalog.effects.map(\.name)))
        #expect(unique(AssetCatalog.callouts.map(\.id)))
        #expect(unique(AssetCatalog.cursors.map(\.id)))
        #expect(unique(AssetCatalog.clickEffects.map(\.id)))
        #expect(unique(AssetCatalog.fonts.map(\.id)))
    }

    @Test func lookupsFindItems() {
        #expect(AssetCatalog.transition(named: "Fade")?.displayName == "Fade")
        #expect(AssetCatalog.effect(named: "DropShadow")?.category == "categoryVisualEffects")
        #expect(AssetCatalog.background(id: "wizrec-aurora") != nil)
        #expect(AssetCatalog.callout(id: "bubble-speech")?.shape == "speech-bubble")
        #expect(AssetCatalog.cursor(id: "arrow")?.hotspot == SIMD2(4, 2))
        #expect(AssetCatalog.clickEffect(id: "ring")?.style == .ring)
        #expect(AssetCatalog.transition(named: "Nope") == nil)
    }

    @Test func requiredTransitionsArePresent() {
        let names = Set(AssetCatalog.transitions.map(\.name))
        for n in ["Fade", "Dissolve", "FadeThroughBlack", "SlideLeft", "SlideRight", "CubeRotate", "BarnDoor", "Iris"] {
            #expect(names.contains(n), "missing \(n)")
        }
        #expect(AssetCatalog.transitions.allSatisfy { $0.defaultDuration > 0 && $0.glsl.contains("void main") })
    }

    @Test func effectPresetsAreOnesTheCompositorDraws() {
        for e in AssetCatalog.effects {
            #expect(Compositor.renderedEffects.contains(e.name), "\(e.name) is not drawn")
            #expect(!e.parameters.isEmpty)
            #expect(Set(e.parameters.map(\.key)).count == e.parameters.count)
        }
    }

    /// `uniform <type> _<Name>;` declarations in a shader, in order.
    private func uniforms(_ glsl: String) -> [(type: String, name: String)] {
        glsl.split(separator: "\n").compactMap { line in
            let w = line.trimmingCharacters(in: .whitespaces).split(separator: " ")
            guard w.count == 3, w[0] == "uniform", w[2].hasPrefix("_"), w[2].hasSuffix(";") else { return nil }
            return (String(w[1]), String(w[2].dropFirst().dropLast()))
        }
    }

    @Test func backgroundUniformsMatchParameters() {
        for bg in AssetCatalog.backgrounds {
            let u = uniforms(bg.glsl)
            #expect(u.map(\.name) == bg.parameters.map(\.name), "\(bg.id)")
            for (decl, p) in zip(u, bg.parameters) {
                let expected = switch p.kind { case .color: "vec4"; case .double, .bool: "float"; case .position: "vec2" }
                #expect(decl.type == expected, "\(bg.id).\(p.name)")
                if case .double(let v) = p.defaultValue {
                    #expect(p.range?.contains(v) == true, "\(bg.id).\(p.name) default out of range")
                }
            }
        }
    }

    @Test func shaderVidFileRoundTripsThroughTheRenderEngineReader() throws {
        for bg in AssetCatalog.backgrounds {
            let data = try bg.shaderVidData()
            #expect(try bg.shaderVidData() == data, "deterministic bytes")
            let file = try ShaderVidFile(data: data)
            #expect(file.code == bg.glsl)
            #expect(file.name == bg.displayName)
            #expect(file.width == 1920 && file.height == 1080)
            for p in bg.parameters {
                switch p.defaultValue {
                case .color(let c):
                    let d = file.defaults[p.name]
                    let expect = ShaderVidFile.Default.color(SIMD4(Float(c.red), Float(c.green), Float(c.blue), 1))
                    #expect(d == expect, "\(bg.id).\(p.name)")
                case .double(let v):
                    #expect(file.defaults[p.name] == .scalar(v), "\(bg.id).\(p.name)")
                default: break
                }
            }
            let keys = bg.sourceEffectParameters.map(\.key)
            #expect(Set(keys).count == keys.count)
            #expect(keys.contains("Speed"))
        }
    }

    @Test func colourHexRoundTrips() {
        #expect(AssetColor(hex: "#5E0CBB")?.hex == "5E0CBB")
        #expect(AssetColor(hex: "11223380")?.hex == "11223380")
        #expect(AssetColor(hex: "xyz") == nil)
        let c = AssetParameter(name: "Color0", displayName: "C", kind: .color, defaultValue: .color(AssetColor(1, 0, 0.5)))
        #expect(c.projectDefaults.map(\.key) == ["Color0-red", "Color0-green", "Color0-blue", "Color0-alpha"])
        #expect(c.uniformName == "_Color0")
    }

    @Test func calloutDefinitionsHaveProjectForm() {
        for p in AssetCatalog.callouts {
            let d = p.definition
            let keys = d.map(\.key)
            #expect(Set(keys).count == keys.count, "\(p.id) duplicate keys")
            #expect(keys.prefix(3) == ["kind", "shape", "style"])
            #expect(keys.contains("fill-color-red") && keys.contains("stroke-color-opacity"))
            if p.kind == "remix" {
                #expect(p.style == "basic")
                #expect(keys.contains("font") && keys.contains("text"))
            } else {
                #expect(p.style == "" && p.shape == "")
                #expect(!keys.contains("font"))
            }
            if p.shape == "arrow" {
                #expect(p.tail != nil && p.anchorCap != nil && p.tailCap != nil)
                #expect(!keys.contains("width"))
            }
        }
        let families = Set(AssetCatalog.fonts.map(\.family))
        for p in AssetCatalog.callouts where p.kind == "remix" {
            #expect(families.contains(p.fontName), "\(p.id) uses a font we do not bundle")
        }
    }
}

@Suite struct ArtTests {
    private func alpha(_ img: CGImage, _ x: Int, _ y: Int) -> UInt8 {
        guard let data = img.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return 0 }
        return p[y * img.bytesPerRow + x * 4 + 3]
    }

    private func opaquePixels(_ img: CGImage) -> Int {
        var n = 0
        for y in 0..<img.height { for x in 0..<img.width where alpha(img, x, y) > 0 { n += 1 } }
        return n
    }

    @Test func cursorsRenderAtScaleWithInkUnderTheHotspot() throws {
        for c in AssetCatalog.cursors {
            let img = try #require(c.image(scale: 2))
            #expect(img.width == 64 && img.height == 64)
            #expect((0...c.width).contains(c.hotspot.x) && (0...c.height).contains(c.hotspot.y))
            // Some pixel within 2 pt of the hotspot is painted (y down in the image too).
            let hx = Int(c.hotspot.x * 2), hy = Int(c.hotspot.y * 2)
            var hit = false
            for dy in -4...4 { for dx in -4...4 where alpha(img, min(max(hx + dx, 0), 63), min(max(hy + dy, 0), 63)) > 128 {
                hit = true
            } }
            #expect(hit, "\(c.id): nothing drawn at the hotspot")
            // Corners stay transparent.
            #expect(alpha(img, 63, 0) == 0 || c.id == "crosshair")
            let png = try #require(c.pngData(scale: 1))
            #expect(png.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
        }
    }

    @Test func arrowTipIsAtTheTopLeft() throws {
        let img = try #require(AssetCatalog.cursor(id: "arrow")?.image(scale: 2))
        // The arrow body is below-right of the tip, never above it.
        #expect(alpha(img, 10, 30) > 128)
        #expect(alpha(img, 10, 60) == 0)
    }

    @Test func clickEffectsAnimateAndEndTransparent() throws {
        for e in AssetCatalog.clickEffects {
            let mid = try #require(e.image(progress: 0.3))
            #expect(mid.width == Int(e.size * 2))
            #expect(opaquePixels(mid) > 0, "\(e.id) draws nothing mid-way")
            let end = try #require(e.image(progress: 1))
            #expect(opaquePixels(end) == 0, "\(e.id) not transparent at the end")
            #expect(e.duration > 0)
        }
    }
}

@Suite struct FontTests {
    /// SHA-256 of the unmodified upstream files; must match THIRD_PARTY_NOTICES.md.
    static let hashes: [String: String] = [
        "Montserrat-wght.ttf": "0f7b311b2f3279e4eef9b2f968bcdbab6e28f4daeb1f049f4f278a902bcd82f7",
        "Lato-Regular.ttf": "d636e4683231f931eda222d588e944d082bfd3bdba02f928bee461c0f185b251",
        "Lato-Bold.ttf": "8a0aace75d33794eece4b28187bfc1df0bbd2888b5d8a56e01788c8d65d16be1",
        "BebasNeue-Regular.ttf": "08e4623805102d819f58601e46e345648846075e363b2ceb23313c2d1c83ec73",
        "Caveat-wght.ttf": "0bdb6b660482d31531b3945849fba5916b3ef8695da7024a9e6b9ee3c4157988",
    ]

    @Test func filesAreBundledUnmodifiedWithLicences() throws {
        for f in AssetCatalog.fonts {
            let url = try #require(f.url, "\(f.fileName) not in the resource bundle")
            let digest = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
            #expect(digest == Self.hashes[f.fileName], "\(f.fileName)")
            let licence = try String(contentsOf: try #require(f.licenseURL), encoding: .utf8)
            #expect(licence.contains("SIL Open Font License"))
        }
    }

    @Test func registeredFamiliesResolveByName() throws {
        let families = AssetFonts.registerAll()
        #expect(families == ["Bebas Neue", "Caveat", "Lato", "Montserrat"])
        #expect(AssetFonts.registerAll() == families)
        for family in families {
            let font = CTFontCreateWithName(family as CFString, 24, nil)
            #expect(CTFontCopyFamilyName(font) as String == family)
        }
    }
}
