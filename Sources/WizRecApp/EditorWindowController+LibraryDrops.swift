import AppKit
import Captions
import PlayerKit
import TimelineEngine
import TimelineUI
import TSCProjKit
import WizRecAssets

/// A library tile being dragged: what kind, from its pasteboard type (ui-workflow.md §4).
@MainActor
enum LibraryDragKind: CaseIterable {
    case effect, transition, callout, background, audio, animation, captionStyle

    var type: NSPasteboard.PasteboardType {
        switch self {
        case .effect: TimelineView.effectType
        case .transition: TimelineView.transitionType
        case .callout: TimelineView.calloutType
        case .background: TimelineView.backgroundType
        case .audio: TimelineView.audioItemType
        case .animation: TimelineView.animationType
        case .captionStyle: TimelineView.captionStyleType
        }
    }

    /// Effects, transitions, audio effects and animations go onto a clip; annotations and
    /// backgrounds onto the canvas or timeline at a time.
    var needsClip: Bool { [.effect, .transition, .audio, .animation, .captionStyle].contains(self) }

    static var types: [NSPasteboard.PasteboardType] { allCases.map(\.type) }

    /// The tile on `pasteboard`, if any.
    static func read(_ pasteboard: NSPasteboard) -> (kind: LibraryDragKind, name: String)? {
        for item in pasteboard.pasteboardItems ?? [] {
            for k in allCases {
                if let n = item.string(forType: k.type), !n.isEmpty { return (k, n) }
            }
        }
        return nil
    }
}

/// Library tiles dropped on the canvas and the timeline: an annotation at the drop time (canvas:
/// the playhead), a background there, an effect / transition / audio effect / animation on the
/// clip under the pointer. One undo step each.
extension EditorWindowController {
    /// `TimelineModel.onLibraryDrop` (annotations, backgrounds, audio effects, animations).
    func timelineLibraryDrop(_ type: NSPasteboard.PasteboardType, _ name: String, _ target: TimelineLibraryTarget,
                             perform: Bool) -> Bool {
        guard let kind = LibraryDragKind.allCases.first(where: { $0.type == type }) else { return false }
        let grouped = !timelineModel.openGroups.isEmpty
        return libraryDrop(kind, name, clip: target.clipID, at: target.ticks, track: grouped ? nil : target.track,
                           perform: perform)
    }

    /// Whether (`perform` false) or that (`perform` true) tile `name` of `kind` goes onto `clip`
    /// (shown-level id; required for clip items) or at `ticks` (project time) on `track`
    /// (nil = the item's own rule).
    func libraryDrop(_ kind: LibraryDragKind, _ name: String, clip: Int64?, at ticks: Int64, track: Int?,
                     perform: Bool) -> Bool {
        if kind.needsClip, clip == nil { return false }
        switch kind {
        case .effect:
            guard let clip, TimelineLibrary.effect(named: name) != nil else { return false }
            return !perform || timelineView.addEffect(named: name, to: clip)
        case .transition:
            guard let clip, TimelineLibrary.transition(named: name) != nil else { return false }
            return !perform || timelineView.applyTransition(named: name, toEdgesOf: clip)
        case .callout:
            guard let preset = AssetCatalog.callout(id: name) else { return false }
            return !perform || insertCallout(preset, at: ticks)
        case .background:
            guard let bg = AssetCatalog.background(id: name) else { return false }
            return !perform || placeBackground(bg, at: ticks, track: track)
        case .audio:
            guard let clip, let item = AudioPanelItem(rawValue: name),
                  !AudioPanel.audioClips(in: model.project, selection: [clip]).isEmpty else { return false }
            guard perform else { return true }
            select([clip])
            return applyAudioItem(item)
        case .animation:
            guard let clip, let preset = AnimationPreset(rawValue: name),
                  AddAnimation.canApply(preset, clipID: clip, in: model.project) else { return false }
            guard perform else { return true }
            var ok = false
            run(String(localized: "Add Animation")) {
                try model.perform(AddAnimation(clipID: clip, preset: preset, at: engine.currentTicks))
                ok = true
            }
            if ok { select([clip]) }
            return ok
        case .captionStyle:
            // A dynamic caption style onto a clip with audio: transcribe it if needed, then add the
            // caption over it (ui-workflow.md §4).
            guard let clip, let index = DynamicCaptionPreset.all.firstIndex(where: { $0.presetID == name }),
                  !CaptionTarget.find(in: model.project, selection: [clip]).isEmpty else { return false }
            guard perform else { return true }
            select([clip])
            addDynamicCaptions(presetIndex: index)
            return true
        }
    }

    /// Animations library double-click: animation `name` on every selected clip it fits (1 s
    /// ending at the playhead), one undo step.
    func applyAnimation(_ name: String) -> Bool {
        guard let preset = AnimationPreset(rawValue: name) else { return false }
        let ids = timelineModel.selection.sorted().filter { AddAnimation.canApply(preset, clipID: $0, in: model.project) }
        guard !ids.isEmpty else {
            ui.show(String(localized: "Select clips with a picture on the timeline first, or drag the animation onto a clip."))
            return false
        }
        let at = engine.currentTicks
        var ok = false
        run(String(localized: "Add Animation")) {
            let steps: [CompoundCommand.Builder] = ids.map { id in { _, _ in AddAnimation(clipID: id, preset: preset, at: at) } }
            try model.perform(CompoundCommand(name: String(localized: "Add Animation"), steps))
            ok = true
        }
        return ok
    }

    /// A tile dropped on the canvas at view point `p` (canvas px `point`, nil outside the
    /// canvas): clip items go to the clip drawn there, the others at the playhead.
    func canvasLibraryDrop(_ kind: LibraryDragKind, _ name: String, point: CGPoint?, perform: Bool) -> Bool {
        var clip: Int64?
        if let point { clip = CanvasHitTest.clip(at: point, plan: engine.drawState().plan, project: model.project) }
        let ok = libraryDrop(kind, name, clip: clip, at: engine.currentTicks, track: nil, perform: perform)
        let highlight = ok && kind.needsClip ? clip : nil
        if ui.canvasDropClip != highlight { ui.canvasDropClip = highlight; refreshCanvasOverlay() }
        if perform {
            print("WizRec: library drop \(kind) \(name) clip=\(clip.map(String.init) ?? "none") ok=\(ok)")  // UI checks
            fflush(stdout)
        }
        return ok
    }
}
