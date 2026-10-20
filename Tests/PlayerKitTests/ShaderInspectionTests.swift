import Foundation
import Testing
import TimelineEngine
import TSCProjKit
import WizRecAssets
@testable import PlayerKit

/// The inspector's view of a shader background (`ShaderInspection`) and its edits through
/// `SetSourceEffectParameters`: one undo step each, keyframes when animated.
@MainActor @Suite struct ShaderInspectionTests {
    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("wizrec-shader-inspect-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func shader(_ doc: EditorDocumentModel, _ clip: Int64, at playhead: Int64 = 0) throws -> ShaderInspection {
        let i = try #require(ClipInspection.make(project: doc.project, clipID: clip, playhead: playhead))
        return try #require(i.shader)
    }

    private func aurora() throws -> BackgroundAsset {
        try #require(AssetCatalog.background(id: "wizrec-aurora") as BackgroundAsset?)
    }

    @Test func libraryBackgroundShowsItsParameters() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let doc = try EditorDocumentModel.untitled(in: dir)
        let clip = try await doc.placeBackground(try aurora(), at: 0)
        let s = try shader(doc, clip)
        #expect(s.title == "Aurora")
        #expect(s.items.map(\.name) == ["Color0", "Color1", "Color2", "Speed", "Intensity"])
        #expect(s.items.map(\.label) == ["Sky", "Glow 1", "Glow 2", "Speed", "Intensity"])
        #expect(s.items[0].kind == .color && s.items[0].keys == ["Color0-red", "Color0-green", "Color0-blue", "Color0-alpha"])
        let sky: [Double] = [0x02, 0x06, 0x17].map { Double($0) / 255 } + [1]
        for (a, b) in zip(s.items[0].values, sky) { #expect(abs(a - b) < 1e-9) }
        #expect(s.items[3].kind == .number(range: 0...5, unit: .plain))
        #expect(s.items[4].kind == .number(range: 0...2, unit: .percentage))
        #expect(s.items.allSatisfy { !$0.animated })
        #expect(s.keyframeTime == 0)
    }

    @Test func colourEditIsOneUndoStep() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let doc = try EditorDocumentModel.untitled(in: dir)
        let clip = try await doc.placeBackground(try aurora(), at: 0)
        let before = doc.project.serialized()
        let changes = try shader(doc, clip).parameterChanges("Color1", [1, 0, 0.5, 1])
        #expect(changes.count == 4 && changes.allSatisfy { $0.isSourceEffect && $0.keyframeAt == nil })
        try doc.set(changes)
        #expect(doc.undo.undoName == "Change Background")
        #expect(try shader(doc, clip).items[1].values == [1, 0, 0.5, 1])
        let after = doc.project.serialized()
        try doc.undoLast()
        #expect(doc.project.serialized() == before)
        try doc.redoLast()
        #expect(doc.project.serialized() == after)
    }

    @Test func sliderPreviewCommitsAsOneStep() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let doc = try EditorDocumentModel.untitled(in: dir)
        let clip = try await doc.placeBackground(try aurora(), at: 0)
        let before = doc.project.serialized()
        let steps = doc.undo.changeCount
        for v in [1.5, 2.5, 3.0] { try doc.preview(try shader(doc, clip).parameterChanges("Speed", [v])) }
        #expect(try shader(doc, clip).items[3].values == [3])
        #expect(doc.undo.changeCount == steps)
        try doc.commitPreview()
        #expect(doc.undo.changeCount == steps + 1)
        #expect(try shader(doc, clip).items[3].values == [3])
        try doc.undoLast()
        #expect(doc.project.serialized() == before)
    }

    @Test func animatedParameterEditsSetKeyframesAtThePlayhead() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let doc = try EditorDocumentModel.untitled(in: dir)
        let clip = try await doc.placeBackground(try aurora(), at: 0)
        let second = doc.project.timebase.editRate
        try doc.perform(SetSourceEffectParameters(clipID: clip, changes: [.init("Speed", 2, keyframeAt: 2 * second)]))
        let s = try shader(doc, clip, at: 5 * second)
        #expect(s.items[3].animated && s.items[3].values == [2])
        #expect(s.keyframeTime == 5 * second)
        let changes = s.parameterChanges("Speed", [4])
        #expect(changes.first?.keyframeAt == 5 * second)
        try doc.set(changes)
        let kfs = doc.project.tracks.flatMap(\.clips).first { $0.id == clip }?
            .object["sourceEffect"]?.object?["parameters"]?.object?["Speed"]?.object?["keyframes"]?.array?.items ?? []
        #expect(kfs.count == 2)
        #expect(kfs.last?.object?["interp"]?.string == "linr")
        #expect(try shader(doc, clip, at: 5 * second).items[3].values == [4])
    }

    /// A user's own shader file with every parameter type (written here; our own content).
    private func customShader(in dir: URL) throws -> URL {
        let file: [String: Any] = [
            "name": "Test Pattern", "version": "1.3", "width": 1920, "height": 1080,
            "effectDef": [
                ["name": "Color0", "type": "Color", "value": "FF8000"],
                ["name": "Angle", "type": "double", "defaultValue": 0.5, "unitType": "radians",
                 "userInterfaceType": "directional"],
                ["name": "Mix", "type": "double", "valueBounds": ["defaultValue": 0.25, "minValue": 0.0, "maxValue": 1.0],
                 "unitType": "percentage"],
                ["name": "Pos", "type": "Position", "value": [100, 200]],
            ],
            "code": "uniform vec4 _Color0; uniform float _Angle; uniform float _Mix; uniform vec2 _Pos;\nvoid main() { _FragColor = _Color0; }",
        ]
        let url = dir.appendingPathComponent("testpattern.tscshadervid")
        try JSONSerialization.data(withJSONObject: file).write(to: url)
        return url
    }

    @Test func userShaderFileShowsEveryParameterKind() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let doc = try EditorDocumentModel.untitled(in: dir)
        let clip = try await doc.importAndInsert(try customShader(in: dir), at: 0)
        let s = try shader(doc, clip)
        #expect(s.title == "testpattern")
        #expect(s.items.map(\.name) == ["Color0", "Angle", "Mix", "Pos"])
        #expect(s.items.map(\.label) == ["Color0", "Angle", "Mix", "Pos"])
        let orange: [Double] = [1, 128.0 / 255, 0, 1]
        for (a, b) in zip(s.items[0].values, orange) { #expect(abs(a - b) < 1e-9) }
        #expect(s.items[1].kind == .number(range: -2 * Double.pi...2 * Double.pi, unit: .angle))
        #expect(s.items[2].kind == .number(range: 0...1, unit: .percentage) && s.items[2].values == [0.25])
        #expect(s.items[3].kind == .position && s.items[3].keys == ["Pos.x", "Pos.y"] && s.items[3].values == [100, 200])

        try doc.set(s.parameterChanges("Pos", [-40, 960]))
        #expect(try shader(doc, clip).items[3].values == [-40, 960])
        try doc.set(s.parameterChanges("Angle", [-1]))
        #expect(try shader(doc, clip).items[1].values == [-1])
    }

    @Test func clipWithoutEffectDefIsReadFromItsKeys() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let doc = try EditorDocumentModel.untitled(in: dir)
        let clip = try await doc.importAndInsert(try customShader(in: dir), at: 0)
        doc.project.sourceBin.first?.object["effectDef"] = nil
        let s = try shader(doc, clip)
        #expect(s.items.map(\.name) == ["Color0", "Angle", "Mix", "Pos"])
        #expect(s.items[0].kind == .color && s.items[3].kind == .position)
        #expect(s.items[1].kind == .number(range: -2 * Double.pi...2 * Double.pi, unit: .angle))
        #expect(s.items[2].kind == .number(range: 0...1, unit: .percentage))
    }

    @Test func fallbackRanges() {
        #expect(ShaderInspection.range(min: 0, max: 10, value: 2, unit: .plain) == 0...10)
        #expect(ShaderInspection.range(min: 0, max: 10, value: 12, unit: .plain) == 0...12)
        #expect(ShaderInspection.range(min: 0, max: 0, value: 0.7, unit: .angle) == -2 * Double.pi...2 * Double.pi)
        #expect(ShaderInspection.range(min: nil, max: nil, value: 3, unit: .plain) == 0...6)
        #expect(ShaderInspection.range(min: nil, max: nil, value: 2, unit: .percentage) == 0...2)
    }

    @Test func ordinaryClipsHaveNoBackgroundSection() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let doc = try EditorDocumentModel.untitled(in: dir)
        let clip = try await doc.placeBackground(try aurora(), at: 0)
        let group = GroupClips(clipIDs: [clip])
        try doc.perform(group)
        let gid = try #require(group.groupID)
        #expect(ClipInspection.make(project: doc.project, clipID: gid, playhead: 0)?.shader == nil)
        // The nested background is still inspectable (constant edits; no keyframe time).
        let nested = try shader(doc, clip)
        #expect(nested.keyframeTime == nil && nested.items.count == 5)
    }
}
