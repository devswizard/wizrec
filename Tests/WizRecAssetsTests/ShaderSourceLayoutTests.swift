import Foundation
import Testing
@testable import WizRecAssets

/// The project form of a shader file's `effectDef` (`docs/specs/shader-backgrounds.md` §6, SH2 code table).
struct ShaderSourceLayoutTests {
    static let file = #"""
    {"name":"t","code":"void main() {}","effectDef":[
      {"name":"Color0","type":"Color","value":"5E0CBB"},
      {"name":"Odd","type":"Color","value":" 130939"},
      {"name":"Speed","type":"double","defaultValue":1,"minValue":0,"maxValue":5},
      {"name":"Mix","type":"double","valueBounds":{"defaultValue":0.5,"minValue":0,"maxValue":1},"unitType":"percentage"},
      {"name":"Fill","type":"double","defaultValue":0.2,"UIUnitType":"percentage"},
      {"name":"Angle","type":"double","defaultValue":0.7,"unitType":"radians","userInterfaceType":"directional"},
      {"name":"Pos","type":"Position","value":[-5000,5000]},
      {"type":"double","defaultValue":3},
      {"name":"Weird","type":"Matrix"}
    ]}
    """#

    @Test func codeTable() throws {
        let e = try ShaderSourceLayout.entries(shaderVid: Data(Self.file.utf8))
        let names: [String] = e.map { $0.name }
        #expect(names == ["Color0", "Odd", "Speed", "Mix", "Fill", "Angle", "Pos", "sourceFileType"])
        func row(_ n: String) throws -> ShaderSourceEntry { try #require(e.first { $0.name == n }) }

        let c = try row("Color0")
        func b(_ v: Int) -> Double { Double(v) / 255 }
        #expect(c.type == "Color")
        #expect([c.scalingType, c.unitType, c.userInterfaceType] == [3, 0, 6] as [Int])
        let rgb: [Double] = [b(0x5E), b(0x0C), b(0xBB), 1]
        #expect(c.defaultValue == .color(rgb))
        #expect(c.clipUIHints == nil)
        let odd: [Double] = [0, b(0x13), b(0x09), b(0x39)]
        #expect(try row("Odd").defaultValue == .color(odd))

        let s = try row("Speed")
        #expect(s.type == "double")
        #expect([s.scalingType, s.unitType, s.userInterfaceType] == [0, 0, 0] as [Int])
        #expect(s.minValue == .double(0) && s.maxValue == .double(5) && s.defaultValue == .double(1))
        let mix = try row("Mix")
        #expect(mix.unitType == 1)
        #expect(mix.defaultValue == .double(0.5))
        #expect(mix.maxValue == .double(1))
        #expect(try row("Fill").unitType == 1)

        let a = try row("Angle")
        #expect([a.unitType, a.userInterfaceType] == [3, 2] as [Int])
        #expect(a.minValue == .double(0) && a.maxValue == .double(0))       // missing range → 0 / 0
        #expect(a.clipUIHints.map { [$0.userInterfaceType, $0.unitType] } == [2, 3] as [Int]?)

        let p = try row("Pos")
        #expect(p.type == "Position")
        #expect([p.scalingType, p.unitType, p.userInterfaceType] == [1, 0, 5] as [Int])
        #expect(p.defaultValue == .position([-5000, 5000, 0]))             // z = 0 appended
        #expect(p.clipUIHints == nil)

        let last = try #require(e.last)
        #expect(last.type == "string" && last.defaultValue == .string("tscshadervid"))
        #expect(last.minValue == .string("") && last.maxValue == .string(""))
    }

    @Test func clipParameterKeys() throws {
        let e = try ShaderSourceLayout.entries(shaderVid: Data(Self.file.utf8))
        let keys = e.flatMap { $0.clipParameters.map(\.key) }
        #expect(keys.prefix(4) == ["Color0-red", "Color0-green", "Color0-blue", "Color0-alpha"])
        #expect(keys.contains("Pos.x") && keys.contains("Pos.y") && !keys.contains("Pos.z"))
        #expect(keys.last == "sourceFileType")
        let pos = try #require(e.first { $0.name == "Pos" }).clipParameters
        let posValues: [ShaderSourceEntry.Value] = [.double(-5000), .double(5000)]
        #expect(pos.map(\.value) == posValues)
    }

    @Test func builtInBackgroundsMapWithoutLoss() throws {
        for bg in AssetCatalog.backgrounds {
            let e = try bg.sourceBinEntries()
            #expect(e.count == bg.parameters.count + 1, "\(bg.id)")
            #expect(e.dropLast().map(\.name) == bg.parameters.map(\.name), "\(bg.id)")
        }
    }

    @Test func assetPositionDefaultsUseDotKeys() {
        let p = AssetParameter(name: "Pos", displayName: "Position", kind: .position, defaultValue: .position(x: 960, y: 540))
        #expect(p.projectDefaults.map(\.key) == ["Pos.x", "Pos.y"])
    }

    @Test func backgroundClipLengthIsSixtySeconds() {
        #expect(ShaderSourceLayout.clipDurationSeconds == 60)
    }
}
