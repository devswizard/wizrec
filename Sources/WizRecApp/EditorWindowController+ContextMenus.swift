import AppKit
import PlayerKit
import TimelineEngine
import TimelineUI
import TSCProjKit

/// Clip, track and canvas context menus (ui-workflow.md §8–§9, our own grouping): the app's
/// items (clipboard, duplicate, ripple cut, group/stitch, captions) join the timeline's own
/// (split, delete, speed, track switches). Every item is the same action as its menu-bar
/// command, validated the same way, and one undo step.
extension EditorWindowController {
    /// A menu item sent to this controller, enabled as its menu-bar twin.
    func menuItem(_ title: String, _ action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = .command,
                  id: String? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = modifiers
        i.target = self
        i.isEnabled = validateMenuItem(i)
        if let id { i.setAccessibilityIdentifier(id) }
        return i
    }

    /// `TimelineModel.contextMenuItems`: the app's items for a timeline context menu.
    func timelineMenuItems(_ context: TimelineMenuContext) -> [TimelineMenuSection: [NSMenuItem]] {
        var out: [TimelineMenuSection: [NSMenuItem]] = [:]
        switch context.target {
        case .clip:
            out[.clipboard] = clipboardItems()
            out[.edit] = [menuItem(String(localized: "Ripple Cut"), #selector(rippleCut(_:)), id: "menu.rippleCut")]
            out[.arrange] = arrangeItems()
            out[.content] = captionItems()
        case .track, .background:
            out[.clipboard] = [menuItem(String(localized: "Paste"), #selector(paste(_:)), key: "v", id: "menu.paste")]
        case .header:
            break
        }
        return out
    }

    func clipboardItems() -> [NSMenuItem] {
        [menuItem(String(localized: "Cut"), #selector(cut(_:)), key: "x", id: "menu.cut"),
         menuItem(String(localized: "Copy"), #selector(copy(_:)), key: "c", id: "menu.copy"),
         menuItem(String(localized: "Paste"), #selector(paste(_:)), key: "v", id: "menu.paste"),
         menuItem(String(localized: "Duplicate"), #selector(duplicate(_:)), key: "d", id: "menu.duplicate")]
    }

    func arrangeItems() -> [NSMenuItem] {
        var items = [menuItem(String(localized: "Group"), #selector(groupClips(_:)), key: "g", id: "menu.group")]
        if kindOfSelection() == .group {
            items.append(menuItem(String(localized: "Ungroup"), #selector(ungroupClip(_:)), key: "G", id: "menu.ungroup"))
        }
        if topLevelSelection.count >= 2 {
            items.append(menuItem(String(localized: "Stitch Selected Media"), #selector(stitchClips(_:)), id: "menu.stitch"))
        }
        if kindOfSelection() == .stitched {
            items.append(menuItem(String(localized: "Unstitch"), #selector(unstitchClip(_:)), id: "menu.unstitch"))
        }
        if kindOfSelection() == .unified {
            items.append(menuItem(String(localized: "Separate Video and Audio"), #selector(detachAudio(_:)), id: "menu.detachAudio"))
        }
        return items
    }

    /// Captions on a clip with audio: add empty ones to type into, or generate them from speech.
    func captionItems() -> [NSMenuItem] {
        guard validateMenuItem(NSMenuItem(title: "", action: #selector(addEmptyCaptions(_:)), keyEquivalent: "")) else { return [] }
        return [menuItem(String(localized: "Generate Captions from Speech"), #selector(generateCaptions(_:)), id: "menu.generateCaptions"),
                menuItem(String(localized: "Add Captions"), #selector(addEmptyCaptions(_:)), id: "menu.addCaptions")]
    }

    // MARK: Actions

    /// Edit ▸ Duplicate (⌘D): copies of the selected clips right after them on the same track
    /// (else a new top track; inside an open group by the group paste rule). One undo step; the
    /// clipboard is not touched.
    @objc func duplicate(_ sender: Any?) {
        let group = timelineModel.openGroups.last
        let ids = model.clipboardSelection(timelineModel.selection, openGroup: group)
        guard !ids.isEmpty else { return }
        let shown = timelineView.snapshot
        let end = ids.compactMap { shown.clip($0)?.clip.end }.max() ?? engine.currentTicks
        let track = model.pasteTrack(timelineModel.selection, openGroup: group)
        Task {
            do {
                let copies = try await model.duplicateClips(ids, end: end, track: track, group: group)
                select(Set(copies))
            } catch {
                ui.show(String(localized: "Duplicate failed: \(Self.describe(error))"))
            }
        }
    }

    /// Timeline ▸ Split All Tracks at Playhead: every top-level clip under the playhead on an
    /// unlocked track, one undo step (TimelineEngine `SplitAllTracks`).
    @objc func splitAllTracks(_ sender: Any?) {
        let c = SplitAllTracks(at: engine.currentTicks)
        run(String(localized: "Split")) { try model.perform(c) }
        if !c.rightIDs.isEmpty { select(Set(c.rightIDs)) }
    }

    /// Edit ▸ Select Clips at Playhead: every top-level clip playing at the playhead.
    @objc func selectAtPlayhead(_ sender: Any?) {
        select(Set(TimelineSelection.clips(at: engine.currentTicks, in: model.project)))
    }

    /// Clips `splitAllTracks` would split (strictly under the playhead, unlocked tracks).
    var canSplitAllTracks: Bool {
        let t = engine.currentTicks
        return TimelineSelection.clips(at: t, in: model.project, unlockedOnly: true).contains { id in
            model.project.tracks.flatMap(\.clips).contains { $0.id == id && $0.start < t }
        }
    }

    /// Edit ▸ Ripple Cut (⇧⌘X): Cut, closing the gaps the clips leave. One undo step.
    @objc func rippleCut(_ sender: Any?) {
        run(String(localized: "Ripple Cut")) {
            put(try model.rippleCutClips(model.clipboardSelection(timelineModel.selection,
                                                                  openGroup: timelineModel.openGroups.last)))
            select([])
        }
    }

    // MARK: Canvas

    /// The canvas context menu for the clip under the pointer (selected first), or for the
    /// empty canvas: clipboard, delete, scale presets, crop mode, arrange, split.
    func canvasMenu(clip: Int64?) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func section(_ items: [NSMenuItem]) {
            guard !items.isEmpty else { return }
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            items.forEach(menu.addItem)
        }
        guard clip != nil else {
            section([menuItem(String(localized: "Paste"), #selector(paste(_:)), key: "v", id: "menu.paste")])
            return menu
        }
        section(clipboardItems())
        let del = menuItem(String(localized: "Delete"), #selector(delete(_:)), id: "menu.delete")
        section([del, menuItem(String(localized: "Split at Playhead"), #selector(splitAtPlayhead(_:)), id: "menu.split")])
        let crop = menuItem(String(localized: "Crop Mode"), #selector(toggleCropMode(_:)), id: "menu.cropMode")
        crop.state = ui.cropMode ? .on : .off
        section(canvasScaleItems() + [crop])
        section(arrangeItems())
        return menu
    }

    /// Scale ▸ Fit, Fill, 200 / 100 / 50 / 25 % of the media's own size (one undo step each).
    func canvasScaleItems() -> [NSMenuItem] {
        let sub = NSMenu()
        sub.autoenablesItems = false
        let ok = canvasScaleTarget != nil
        for (title, tag) in [(String(localized: "Fit to Canvas"), -1), (String(localized: "Fill Canvas"), -2),
                             ("200 %", 200), ("100 %", 100), ("50 %", 50), ("25 %", 25)] {
            let i = NSMenuItem(title: title, action: #selector(scaleSelection(_:)), keyEquivalent: "")
            i.target = self; i.tag = tag; i.isEnabled = ok
            sub.addItem(i)
        }
        let parent = NSMenuItem(title: String(localized: "Scale"), action: nil, keyEquivalent: "")
        parent.submenu = sub
        parent.isEnabled = ok
        return [parent]
    }

    /// The selected clip's inspection and its media size (canvas px at scale 1) when it can be
    /// scaled on the canvas.
    var canvasScaleTarget: (inspection: ClipInspection, size: CGSize)? {
        guard timelineModel.selection.count == 1, let id = timelineModel.selection.first,
              let i = inspection(of: id), i.visualClipID != nil,
              let size = CanvasGeometry.mediaSize(of: id, plan: engine.drawState().plan, project: model.project)
        else { return nil }
        return (i, size)
    }

    /// Scale menu: tag −1 fit, −2 fill, else percent.
    @objc func scaleSelection(_ sender: NSMenuItem) {
        guard let (i, size) = canvasScaleTarget, size.width > 0, size.height > 0 else { NSSound.beep(); return }
        let canvas = model.scene.canvasSize
        let fit = min(canvas.width / size.width, canvas.height / size.height)
        let fill = max(canvas.width / size.width, canvas.height / size.height)
        let s: Double = switch sender.tag {
        case -1: fit
        case -2: fill
        default: Double(sender.tag) / 100
        }
        var changes = i.changes(.scale, s)
        if sender.tag < 0 { changes += i.changes(.positionX, 0) + i.changes(.positionY, 0) }
        run(String(localized: "Scale")) { try model.set(changes) }
    }
}
