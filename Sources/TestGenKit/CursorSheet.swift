import Foundation
import TimelineEngine
import TSCProjKit

/// CE3 (`docs/specs/cursor-effects.md` §5): the user's own Camtasia recording placed six
/// times, each with a cursor setting, to pin down `CursorColor` and `CursorShadow`.
///
/// Unlike the other sheets it needs the user's recording, so the user runs
/// `wizrec-testgen ce3 <recording.trec>` during the Camtasia session. The project is built
/// the way the app builds one: `ProjectBundle.create` + `importFile`, then TimelineEngine
/// commands (`AddSource`, `AddTrack`, `InsertClip`, `SetParameter`, `AddEffect`).
public enum CursorSheet {
    public static let name = "ce3-cursor"

    /// Cursor effects at the demo values (key sets from the demo's `ScreenVMFile` 6).
    public static func cursorColor(intensity: Double = 1, swapped: Bool = false) -> JSONObject {
        let black: [Double] = [0, 0, 0, 1], yellow: [Double] = [1, 0.8980392157, 0.1215686275, 1]
        let (first, second) = swapped ? (yellow, black) : (black, yellow)
        return EffectJSON.make("CursorColor", category: "categoryCursorEffects", [
            ("intensity", .double(intensity)), ("desaturation", .double(0)), ("colorLumaCutoff", .double(1)),
            ("color-alpha", .double(first[3])), ("color-red", .double(first[0])), ("color-green", .double(first[1])),
            ("color-blue", .double(first[2])),
            ("secondColor-red", .double(second[0])), ("secondColor-green", .double(second[1])),
            ("secondColor-blue", .double(second[2])), ("secondColor-alpha", .double(second[3])),
            ("secondColorLumaCutoff", .double(0)),
        ] + EffectJSON.rangeDefaults)
    }

    /// `CursorShadow` (DropShadow's key set) with the demo's colour and opacity.
    public static func cursorShadow(angle: Double, offset: Double, blur: Double, opacity: Double = 0.5) -> JSONObject {
        EffectJSON.make("CursorShadow", category: "categoryCursorEffects", [
            ("angle", .double(angle)), ("enabled", .int(1)), ("offset", .double(offset)), ("blur", .double(blur)),
            ("opacity", .double(opacity)), ("color-red", .double(0)), ("color-green", .double(0)),
            ("color-blue", .double(0)), ("color-alpha", .double(1)),
        ])
    }

    /// The six copies: (`cursorScale`, effects, settings text, what it answers).
    static func copies() -> [(Double, [JSONObject], String, String)] {
        [
            (4, [cursorColor()], "cursorScale 4, CursorColor demo values (black / yellow)", "luma → colour mapping"),
            (4, [cursorColor(swapped: true)], "cursorScale 4, CursorColor with the colours swapped", "which stop is which"),
            (4, [cursorColor(intensity: 0.5)], "cursorScale 4, CursorColor intensity 0.5", "intensity mix"),
            (4, [cursorShadow(angle: 0, offset: 20, blur: 0)], "cursorScale 4, CursorShadow angle 0, offset 20, blur 0",
             "shadow direction and units on the cursor"),
            (1, [], "cursorScale 1, no effect", "natural cursor size"),
            (4, [], "cursorScale 4, no effect", "cursorScale reference"),
        ]
    }

    /// Builds `<caseDir>/ce3-cursor.cmproj` from `recording` and writes `sheet.json`.
    ///
    /// - `describe(file, src)`: probes the copied file and returns its `SourceDescriptor`
    ///   (the CLI uses MediaEngine + PlayerKit; tests pass a fixed descriptor).
    /// - Each copy is scaled to a third of the canvas fit (≤ 640×360) in a 3×2 grid; the
    ///   playhead is parked at min(5 s, half the recording).
    /// Replaces an existing bundle.
    @MainActor @discardableResult
    public static func write(recording: URL, to caseDir: URL,
                             describe: (URL, String) async throws -> SourceDescriptor) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: caseDir, withIntermediateDirectories: true)
        let bundleURL = caseDir.appendingPathComponent("\(name).cmproj", isDirectory: true)
        try? fm.removeItem(at: bundleURL)
        let bundle = try ProjectBundle.create(at: bundleURL, width: 1920, height: 1080, fps: 30)
        let src = try bundle.importFile(recording)
        let copied = bundle.directory.appendingPathComponent(String(src.dropFirst(2)))
        let descriptor = try await describe(copied, src)
        guard let video = descriptor.tracks.first(where: { $0.type == 0 }), video.width > 0, video.height > 0 else {
            throw MediaWriterError.setup("\(recording.lastPathComponent) has no video stream")
        }
        let undo = UndoStack(project: bundle.project)
        let add = AddSource(descriptor)
        try undo.perform(add)
        guard let sourceID = add.sourceID else { throw MediaWriterError.setup("AddSource gave no id") }

        let fit = min(1920 / Double(video.width), 1080 / Double(video.height))
        let scale = fit / 3
        let g = Grid(cols: 3, rows: 2)
        var cells: [SheetCell] = []
        var duration: Int64 = 0
        for (i, copy) in copies().enumerated() {
            if i > 0 { try undo.perform(AddTrack(at: i)) }
            let insert = InsertClip(sourceID: sourceID, track: i, start: 0)
            try undo.perform(insert)
            guard let clipID = insert.clipID else { throw MediaWriterError.setup("InsertClip gave no id") }
            let p = g.centre(i)
            for (k, v) in [("translation0", p.x), ("translation1", p.y), ("scale0", scale), ("scale1", scale),
                           ("cursorScale", copy.0)] {
                try undo.perform(SetParameter(clipID: clipID, parameter: k, value: v))
            }
            for e in copy.1 { try undo.perform(AddEffect(clipID: clipID, effectJSON: EffectJSON.string(e))) }
            cells.append(SheetCell(id: i + 1, rect: g.rect(i), settings: copy.2, answers: copy.3))
            duration = max(duration, bundle.project.tracks.flatMap(\.clips).map(\.end).max() ?? 0)
        }
        try bundle.saveWithBackup()
        let frame = Int64(23_520_000)
        let playhead = min(5 * 705_600_000, (duration / 2) / frame * frame)
        try DocPrefs.write(playhead: playhead, to: bundleURL)
        let manifest = SheetManifest(
            caseName: name, group: "research/cursor",
            summary: "CE3 cursor sheet: the user's recording six times (3×2), cursorScale 4 with CursorColor (demo, swapped, intensity 0.5), CursorShadow, and two size references.",
            status: "ready", project: "\(name).cmproj", requires: ["CursorColor", "CursorShadow", "Cursor"],
            referenceImage: "reference.png", referenceMovie: nil, movieFrames: nil,
            playheadFrame: Int(playhead / frame), fps: 30, width: 1920, height: 1080, ssimMin: 0.95, cells: cells,
            checklist: "Six small copies of your recording; the cursor is large in five of them, yellow/black in three, with a hard shadow in one.",
            generator: TestGen.version)
        try manifest.write(to: caseDir.appendingPathComponent("sheet.json"))
        return bundleURL
    }
}
