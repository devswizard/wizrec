import AppKit
import TimelineEngine

// Additive public API (API_CHANGE TimelineUI, session 11, APP15-1b): library tiles the app
// places itself (annotations, backgrounds, audio effects, animations) can be dropped on the
// timeline; the canvas takes effects and transitions on a clip through `TimelineView`.

/// Where an app-handled library tile is dropped on the timeline.
public struct TimelineLibraryTarget: Sendable, Equatable {
    /// The clip under the pointer (shown level), if any.
    public var clipID: Int64?
    /// Track row under the pointer (shown level, 0 = bottom); the nearest row when between rows.
    public var track: Int
    /// Display (project timeline) time under the pointer, ticks, frame-rounded.
    public var ticks: Int64

    public init(clipID: Int64?, track: Int, ticks: Int64) { self.clipID = clipID; self.track = track; self.ticks = ticks }
}

extension TimelineView {
    /// Library drags: string = annotation preset id (`AssetCatalog.callouts`).
    public static let calloutType = NSPasteboard.PasteboardType("com.devswizard.wizrec.callout")
    /// Library drags: string = background id (`AssetCatalog.backgrounds`).
    public static let backgroundType = NSPasteboard.PasteboardType("com.devswizard.wizrec.background")
    /// Library drags: string = audio panel item (`AudioPanelItem` raw value), dropped on a clip with audio.
    public static let audioItemType = NSPasteboard.PasteboardType("com.devswizard.wizrec.audio-item")
    /// Library drags: string = animation preset, dropped on a clip.
    public static let animationType = NSPasteboard.PasteboardType("com.devswizard.wizrec.animation")
    /// The library types `TimelineModel.onLibraryDrop` handles.
    public static let appLibraryTypes: [NSPasteboard.PasteboardType] = [calloutType, backgroundType, audioItemType, animationType]

    /// Adds library effect `name` to clip `clipID` (shown level), one undo step (a drop on the canvas).
    @discardableResult
    public func addEffect(named name: String, to clipID: Int64) -> Bool { editor.addEffect(named: name, to: clipID) }

    /// Adds library transition `name` to both edges of clip `clipID` (two-sided where a neighbour
    /// touches, a fade in/out where none does), one undo step (a drop on a clip on the canvas).
    @discardableResult
    public func applyTransition(named name: String, toEdgesOf clipID: Int64) -> Bool {
        editor.applyTransition(named: name, toEdgesOf: clipID)
    }
}

extension TimelineEditor {
    /// Library transition `name` on both edges of clip `clipID`; see `TimelineView.applyTransition(named:toEdgesOf:)`.
    @discardableResult
    public func applyTransition(named name: String, toEdgesOf clipID: Int64) -> Bool {
        guard let (track, c) = snapshot.clip(clipID), let t = snapshot.track(track), !t.locked else { return false }
        let pairs: [(Int64?, Int64?)] = [(t.clips.first { $0.end == c.start }?.id, c.id),
                                         (c.id, t.clips.first { $0.start == c.end }?.id)]
        let cmds: [any EditCommand] = pairs.map { l, r in
            let d = transitionDuration(left: l, right: r, name: name)
            return AddTransition(name: name, leftClipID: l, rightClipID: r,
                                 duration: map.isIdentity ? d : max(1, Int64((Double(d) / map.scale).rounded())))
        }
        return perform(CompositeCommand(name: "Add Transition", cmds))
    }
}

extension TimelineCanvas {
    /// An app-handled library tile on the pasteboard: its type and name.
    func appLibraryItem(_ pb: NSPasteboard) -> (type: NSPasteboard.PasteboardType, name: String)? {
        for item in pb.pasteboardItems ?? [] {
            for type in TimelineView.appLibraryTypes {
                if let n = item.string(forType: type), !n.isEmpty { return (type, n) }
            }
        }
        return nil
    }

    /// The app drop at view point `p` when the app accepts it there (asked with `perform` false).
    func appLibraryDrop(_ item: (type: NSPasteboard.PasteboardType, name: String), at p: CGPoint) -> LibraryDrop? {
        let target = appLibraryTarget(at: p)
        guard let ask = model.onLibraryDrop, ask(item.type, item.name, target, false) else { return nil }
        return .app(type: item.type.rawValue, name: item.name, target: target)
    }

    /// The target of an app library drop at view point `p`.
    func appLibraryTarget(at p: CGPoint) -> TimelineLibraryTarget {
        let L = layout
        var clip: Int64?
        if case .clip(let id, _, _) = L.hit(p, in: snapshot) { clip = id }
        let track = L.nearestTrack(atY: p.y) ?? 0
        let t = max(0, snapshot.quantize(L.ticks(atX: max(p.x, L.clipArea.minX))))
        return TimelineLibraryTarget(clipID: clip, track: track, ticks: t)
    }
}
