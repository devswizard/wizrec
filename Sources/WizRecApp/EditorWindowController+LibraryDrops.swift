import AppKit
import PlayerKit
import TimelineEngine
import TimelineUI
import TSCProjKit
import WizRecAssets

/// A library tile being dragged: what kind, from its pasteboard type (ui-workflow.md §4).
@MainActor
enum LibraryDragKind: CaseIterable {
    case effect, transition, callout, background, audio, animation

    var type: NSPasteboard.PasteboardType {
        switch self {
        case .effect: TimelineView.effectType
        case .transition: TimelineView.transitionType
        case .callout: TimelineView.calloutType
        case .background: TimelineView.backgroundType
        case .audio: TimelineView.audioItemType
        case .animation: TimelineView.animationType
        }
    }

    /// Effects, transitions, audio effects and animations go onto a clip; annotations and
    /// backgrounds onto the canvas or timeline at a time.
    var needsClip: Bool { [.effect, .transition, .audio, .animation].contains(self) }

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
            return false   // TimelineEngine `AddAnimation` (TL15-2) not merged yet
        }
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
