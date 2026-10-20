import Foundation
import TestGenKit
import Testing
import TSCProjKit

/// Builds every sheet with small media and checks the projects are well-formed and
/// that effect entries have the shape Camtasia writes.
@Suite(.serialized) struct SheetGeneratorTests {
    @Test func sheetsHaveUniqueNamesAndCells() {
        let names = TestGen.sheets.map(\.name)
        #expect(Set(names).count == names.count)
        for s in TestGen.sheets {
            let ids = s.cells.map(\.id)
            #expect(ids == Array(1...ids.count), "\(s.name): cell ids \(ids)")
            for c in s.cells {
                #expect(c.rect.count == 4 && c.rect[0] >= 0 && c.rect[1] >= 0
                        && c.rect[0] + c.rect[2] <= 1920.5 && c.rect[1] + c.rect[3] <= 1080.5, "\(s.name) cell \(c.id)")
            }
            #expect(s.playheadFrame < s.durationFrames)
        }
        // Spec tables: EF1 10 cells, EF2 5, EF3 10, EF4 9, EF5 24, CO1 20.
        let counts = Dictionary(uniqueKeysWithValues: TestGen.sheets.map { ($0.name, $0.cells.count) })
        #expect(counts["ef1-dropshadow"] == 10 && counts["ef2-roundcorners"] == 5 && counts["ef3-mask"] == 10)
        #expect(counts["ef4-coloradjust"] == 9 && counts["ef5-blendmode"] == 24 && counts["co1-shapes"] == 20)
        let placeholders: [String] = TestGen.sheets.filter(\.isPlaceholder).map(\.name)
        #expect(placeholders == ["ef8-border", "ef9-reflection"])
    }

    /// Demo `DropShadow`/`RoundCorners`/`Mask` and vlog `ColorAdjustment` key order, by effect.
    static let camtasiaKeys: [String: [String]] = [
        "DropShadow": ["angle", "enabled", "offset", "blur", "opacity", "color-red", "color-green", "color-blue", "color-alpha"],
        "RoundCorners": ["radius", "top-left", "top-right", "bottom-left", "bottom-right"],
        "Mask": ["mask-shape", "mask-opacity", "mask-blend", "mask-invert", "mask-rotation", "mask-width", "mask-height",
                 "mask-positionX", "mask-positionY", "mask-cornerRadius"],
        "ColorAdjustment": ["brightness", "contrast", "saturation", "channel", "shadowRampStart", "shadowRampEnd",
                            "highlightRampStart", "highlightRampEnd"],
    ]

    @Test @MainActor func generatedSheetsRoundTripAndMatchCamtasiaShapes() throws {
        let dir = try scratchDir("sheets")
        defer { try? FileManager.default.removeItem(at: dir) }
        let media = try TestGen.makeSheetMedia(in: dir.appendingPathComponent("_m"), scale: 0.1)
        for sheet in TestGen.sheets {
            let caseDir = try TestGen.write(sheet, media: media, to: dir)
            let manifest = try SheetManifest.load(caseDir.appendingPathComponent("sheet.json"))
            #expect(manifest.caseName == sheet.name && manifest.ssimMin == 0.95)
            if sheet.isPlaceholder {
                #expect(manifest.status == "after-EF0" && manifest.project == nil)
                #expect(FileManager.default.fileExists(atPath: caseDir.appendingPathComponent("PLACEHOLDER-after-EF0.txt").path))
                continue
            }
            let bundleURL = caseDir.appendingPathComponent(try #require(manifest.project))
            let bytes = try Data(contentsOf: bundleURL.appendingPathComponent("project.tscproj"))
            let project = try Project(data: bytes)
            #expect(project.serialized() == bytes, "\(sheet.name): not a TSCProjKit fixed point")
            let bundle = try ProjectBundle(url: bundleURL)
            #expect(bundle.missingMedia().isEmpty)
            #expect(DocPrefs.playhead(in: bundleURL) == Int64(sheet.playheadFrame) * 23_520_000)
            #expect(project.timeline?.backgroundColor == [255, 255, 255, 255])
            #expect(project.tracks.count == project.timeline?.trackAttributes.count)

            var ids = Set<Int64>()
            var effectNames = Set<String>()
            for track in project.tracks {
                #expect(track.clips.count == 1, "\(sheet.name): one clip per track")
                for clip in track.clips {
                    #expect(ids.insert(clip.id).inserted, "\(sheet.name): duplicate id \(clip.id)")
                    let effects = clip.object["effects"]?.array?.items.compactMap(\.object) ?? []
                    for e in effects {
                        let name = try #require(e["effectName"]?.string)
                        effectNames.insert(name)
                        #expect(Array(e.keys.prefix(4)) == ["effectName", "bypassed", "category", "parameters"])
                        #expect(e["category"]?.string == "categoryVisualEffects")
                        let params = try #require(e["parameters"]?.object)
                        if let want = Self.camtasiaKeys[name] { #expect(params.keys == want, "\(name) keys") }
                        for (k, v) in params.entries {
                            if let o = v.object {
                                #expect(o.keys == ["type", "defaultValue", "interp", "uiHints"], "\(name).\(k)")
                                #expect(o["interp"]?.string == "linr")
                            } else {
                                #expect(v.number?.isInteger == true, "\(name).\(k): constants are ints")
                            }
                        }
                    }
                    if let last = effects.last?["effectName"]?.string {
                        #expect(clip.object["metadata"]?.object?["effectApplied"]?.string == last)
                    }
                }
            }
            #expect(effectNames.isSubset(of: Set(manifest.requires)), "\(sheet.name): \(effectNames) ⊄ requires")
        }
    }

    /// CO1 holds every shape id once in basic style; arrows carry animatable tails.
    @Test @MainActor func calloutSheetDefs() throws {
        let dir = try scratchDir("co")
        defer { try? FileManager.default.removeItem(at: dir) }
        let sheet = try #require(TestGen.sheets.first { $0.name == "co1-shapes" })
        let caseDir = try TestGen.write(sheet, media: [:], to: dir)
        let project = try ProjectBundle(url: caseDir.appendingPathComponent("co1-shapes.cmproj")).project
        let defs = project.tracks.flatMap(\.clips).compactMap { $0.object["def"]?.object }
        #expect(defs.count == 20)
        let basic = defs.filter { $0["style"]?.string == "basic" }.compactMap { $0["shape"]?.string }
        #expect(basic == TestGen.calloutShapes)
        let arrow = try #require(defs.first { $0["shape"]?.string == "arrow" })
        #expect(arrow["tail-x"]?.object?["defaultValue"]?.double == 200)
        let text = try #require(defs.first { $0["shape"]?.string == "text" })
        #expect(text["text"]?.string == "Ag Wy 123")
        let runs = text["textAttributes"]?.object?["keyframes"]?.array?[0].object?["value"]?.array?.items.compactMap(\.object) ?? []
        #expect(runs.first { $0["name"]?.string == "fontSize" }?["value"]?.double == 48)
        #expect(runs.allSatisfy { $0["rangeEnd"]?.int == 9 })
    }
}
