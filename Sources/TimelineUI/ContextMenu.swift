import AppKit
import TimelineEngine

/// Where a timeline context menu was opened (passed to `TimelineModel.contextMenuItems`).
public struct TimelineMenuContext: Sendable, Equatable {
    /// What was right-clicked.
    public enum Target: Sendable, Equatable {
        /// A clip (shown level); it is in the selection when the menu opens.
        case clip(Int64)
        /// The empty part of a track row.
        case track
        /// A track header.
        case header
        /// Below the last track, the ruler, the corner or the breadcrumb.
        case background
    }

    public var target: Target
    /// Track index at the shown level (0 = bottom); nil off the rows.
    public var track: Int?
    /// Display (project timeline) time under the pointer, ticks.
    public var ticks: Int64

    public init(target: Target, track: Int?, ticks: Int64) {
        self.target = target; self.track = track; self.ticks = ticks
    }
}

/// Groups of a timeline context menu, in menu order. The timeline fills the sections it can act
/// on itself; the app adds its own items (`TimelineModel.contextMenuItems`) to any section.
public enum TimelineMenuSection: Int, Sendable, CaseIterable, Comparable {
    /// Cut, copy, paste, duplicate (app).
    case clipboard
    /// Split, delete, ripple delete, ripple cut.
    case edit
    /// Group, ungroup, open group, stitch, separate audio (app and timeline).
    case arrange
    /// Clip speed, extend frame.
    case timing
    /// Effects, transitions, captions.
    case content
    /// Track commands (insert, remove, lock, mute, hide, magnetic).
    case tracks
    /// Markers and zoom.
    case view

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

extension TimelineCanvas {
    /// Speeds offered by the clip menu's Clip Speed submenu, percent.
    static let menuSpeeds: [Int] = [25, 50, 75, 100, 150, 200, 400]

    /// Transition on `track` whose window contains view x `x`.
    func transition(onTrack track: Int, atX x: CGFloat) -> TimelineTransitionItem? {
        let t = layout.ticks(atX: x)
        return snapshot.track(track)?.transitions.first { $0.start <= t && t <= $0.end }
    }

    /// The context for `hit` (what the app's extra items act on).
    func menuContext(for hit: TimelineHit, at p: CGPoint) -> TimelineMenuContext {
        let t = max(0, layout.ticks(atX: max(p.x, layout.clipArea.minX)))
        switch hit {
        case .clip(let id, let track, _): return TimelineMenuContext(target: .clip(id), track: track, ticks: t)
        case .track(let track, let ticks): return TimelineMenuContext(target: .track, track: track, ticks: ticks)
        case .header(let track, _): return TimelineMenuContext(target: .header, track: track, ticks: t)
        case .ruler(let ticks): return TimelineMenuContext(target: .background, track: nil, ticks: ticks)
        case .empty(let ticks): return TimelineMenuContext(target: .background, track: nil, ticks: ticks)
        case .breadcrumb, .corner: return TimelineMenuContext(target: .background, track: nil, ticks: t)
        }
    }

    /// The context menu for `hit` at view point `p`: the timeline's own items plus the app's
    /// (`TimelineModel.contextMenuItems`), section by section with separators between.
    func contextMenu(for hit: TimelineHit, at p: CGPoint = .zero) -> NSMenu? {
        var sections: [TimelineMenuSection: [NSMenuItem]] = [:]
        func add(_ s: TimelineMenuSection, _ item: NSMenuItem) { sections[s, default: []].append(item) }
        func item(_ title: String, _ action: Selector, tag: Int = 0, enabled: Bool = true,
                  on: Bool? = nil, object: Any? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = self; i.tag = tag; i.isEnabled = enabled
            i.representedObject = object
            if let on { i.state = on ? .on : .off }
            return i
        }
        switch hit {
        case .clip(let id, let track, _):
            let locked = snapshot.track(track)?.locked ?? true
            add(.edit, item(String(localized: "Split at Playhead"), #selector(menuSplit(_:)),
                            enabled: !editor.splitTargets(at: model.playhead).isEmpty))
            add(.edit, item(String(localized: "Delete"), #selector(menuDelete(_:)), enabled: !editor.deletableSelection.isEmpty))
            add(.edit, item(String(localized: "Ripple Delete"), #selector(menuRippleDelete(_:)),
                            enabled: !editor.deletableSelection.isEmpty))
            if snapshot.clip(id)?.clip.style == .group {
                add(.arrange, item(String(localized: "Open Group"), #selector(menuOpenGroup(_:)), object: NSNumber(value: id)))
            }
            add(.timing, speedMenu())
            add(.timing, item(String(localized: "Extend Frame"), #selector(menuExtendFrame(_:)), enabled: canExtendFrame))
            if let tr = transition(onTrack: track, atX: p.x) {
                let pair = [tr.leftClipID.map { NSNumber(value: $0) } ?? NSNull(),
                            tr.rightClipID.map { NSNumber(value: $0) } ?? NSNull()] as NSArray
                add(.content, item(String(localized: "Remove Transition"), #selector(menuRemoveTransition(_:)),
                                   enabled: !locked, object: pair))
            }
            if let c = snapshot.clip(id)?.clip, !c.effects.isEmpty {
                let sub = NSMenu()
                for e in c.effects {
                    let title = TimelineLibrary.effect(named: e.name)?.displayName ?? e.name
                    sub.addItem(item(title, #selector(menuRemoveEffect(_:)),
                                     object: [NSNumber(value: id), NSNumber(value: e.index)] as NSArray))
                }
                let parent = NSMenuItem(title: String(localized: "Remove Effect"), action: nil, keyEquivalent: "")
                parent.submenu = sub
                parent.isEnabled = !locked
                add(.content, parent)
            }
            for i in trackItems(track) { add(.tracks, i) }
        case .header(let track, _):
            for i in trackItems(track) { add(.tracks, i) }
        case .track(let track, _):
            for i in trackItems(track) { add(.tracks, i) }
            add(.view, item(String(localized: "Zoom to Fit"), #selector(menuZoomToFit(_:))))
        case .ruler(let t):
            add(.view, item(String(localized: "Add Marker at Playhead"), #selector(menuAddMarker(_:))))
            let near = editor.marker(near: t, tolerance: layout.ticks(forWidth: 6)).map { NSNumber(value: $0.time) }
            add(.view, item(String(localized: "Remove Marker"), #selector(menuRemoveMarker(_:)), enabled: near != nil, object: near))
            add(.view, item(String(localized: "Rename Marker…"), #selector(menuRenameMarker(_:)), enabled: near != nil, object: near))
            add(.view, item(String(localized: "Zoom to Fit"), #selector(menuZoomToFit(_:))))
        case .breadcrumb:
            if !snapshot.groupPath.isEmpty { add(.arrange, item(String(localized: "Close Group"), #selector(menuCloseGroup(_:)))) }
        case .empty, .corner:
            add(.tracks, item(String(localized: "Add Track"), #selector(menuAddTrack(_:)), tag: snapshot.tracks.count,
                              enabled: editor.canAddTrack))
            add(.view, item(String(localized: "Zoom to Fit"), #selector(menuZoomToFit(_:))))
        }
        if let extra = model.contextMenuItems?(menuContext(for: hit, at: p)) {
            for (s, items) in extra { sections[s, default: []] += items }
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for s in TimelineMenuSection.allCases {
            guard let items = sections[s], !items.isEmpty else { continue }
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            for i in items { menu.addItem(i) }
        }
        return menu.items.isEmpty ? nil : menu
    }

    /// Track `track`'s items: insert above/below, remove, and its lock / mute / hide / magnetic
    /// switches (checked when on).
    func trackItems(_ track: Int) -> [NSMenuItem] {
        guard let t = snapshot.track(track) else { return [] }
        func item(_ title: String, _ action: Selector, tag: Int, enabled: Bool = true, on: Bool? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = self; i.tag = tag; i.isEnabled = enabled
            if let on { i.state = on ? .on : .off }
            return i
        }
        let add = editor.canAddTrack
        func flag(_ title: String, _ c: TrackHeaderControl, _ on: Bool) -> NSMenuItem {
            let i = item(title, #selector(menuToggleTrackFlag(_:)), tag: track, on: on)
            i.representedObject = c.rawValue
            i.setAccessibilityIdentifier("timeline.menu.\(c.rawValue)")
            return i
        }
        return [
            item(String(localized: "Add Track Above"), #selector(menuAddTrack(_:)), tag: track + 1, enabled: add),
            item(String(localized: "Add Track Below"), #selector(menuAddTrack(_:)), tag: track, enabled: add),
            item(String(localized: "Remove Track"), #selector(menuRemoveTrack(_:)), tag: track, enabled: editor.canRemoveTrack(at: track)),
            .separator(),
            flag(String(localized: "Lock Track"), .locked, t.locked),
            flag(String(localized: "Mute Track Audio"), .audioMuted, t.audioMuted),
            flag(String(localized: "Hide Track Video"), .videoHidden, t.videoHidden),
            flag(String(localized: "Magnetic Track"), .magnetic, t.magnetic),
        ]
    }

    /// Clip Speed ▸ 25 % … 400 % (the selection's current speed is checked); ⌥ ripples.
    func speedMenu() -> NSMenuItem {
        let sub = NSMenu()
        let enabled = !editor.retimableSelection.isEmpty
        let speeds = Set(editor.retimableSelection.compactMap { snapshot.clip($0)?.clip.speed })
        for pct in Self.menuSpeeds {
            let i = NSMenuItem(title: "\(pct) %", action: #selector(menuSetSpeed(_:)), keyEquivalent: "")
            i.target = self; i.tag = pct; i.isEnabled = enabled
            if speeds.count == 1, let s = speeds.first, abs(s * 100 - Double(pct)) < 0.01 { i.state = .on }
            sub.addItem(i)
        }
        let parent = NSMenuItem(title: String(localized: "Clip Speed"), action: nil, keyEquivalent: "")
        parent.submenu = sub
        parent.isEnabled = enabled
        return parent
    }

    var canExtendFrame: Bool {
        editor.retimableSelection.contains { snapshot.clip($0).map { !$0.clip.videoSpans.isEmpty } ?? false }
    }

    @objc func menuSplit(_ sender: Any?) { if !editor.splitAtPlayhead() { NSSound.beep() } }
    @objc func menuDelete(_ sender: Any?) { if !editor.deleteSelection(ripple: false) { NSSound.beep() } }
    @objc func menuRippleDelete(_ sender: Any?) { if !editor.deleteSelection(ripple: true) { NSSound.beep() } }
    @objc func menuAddTrack(_ sender: NSMenuItem) { if !editor.addTrack(at: sender.tag) { NSSound.beep() } }
    @objc func menuRemoveTrack(_ sender: NSMenuItem) { if !editor.removeTrack(at: sender.tag) { NSSound.beep() } }
    @objc func menuToggleTrackFlag(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let c = TrackHeaderControl(rawValue: raw),
              editor.toggle(c, track: sender.tag) else { NSSound.beep(); return }
    }
    @objc func menuSetSpeed(_ sender: NSMenuItem) {
        let ripple = NSApp?.currentEvent?.modifierFlags.contains(.option) ?? false
        if !editor.setSpeed(Double(sender.tag) / 100, ripple: ripple) { NSSound.beep() }
    }
    @objc func menuExtendFrame(_ sender: Any?) { if !editor.extendFrame(seconds: 1) { NSSound.beep() } }
    @objc func menuZoomToFit(_ sender: Any?) { zoomToFit() }
    @objc func menuOpenGroup(_ sender: NSMenuItem) {
        if let id = (sender.representedObject as? NSNumber)?.int64Value { editor.openGroup(id) }
    }
    @objc func menuCloseGroup(_ sender: Any?) { editor.closeGroups(toLevel: snapshot.groupPath.count - 1) }
    @objc func menuRemoveTransition(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? NSArray, pair.count == 2 else { return }
        let l = (pair[0] as? NSNumber)?.int64Value, r = (pair[1] as? NSNumber)?.int64Value
        if !editor.removeTransition(left: l, right: r) { NSSound.beep() }
    }
    @objc func menuRemoveEffect(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? NSArray, pair.count == 2,
              let id = (pair[0] as? NSNumber)?.int64Value, let index = (pair[1] as? NSNumber)?.intValue else { return }
        if !editor.removeEffect(at: index, from: id) { NSSound.beep() }
    }
    @objc func menuAddMarker(_ sender: Any?) { if !editor.addMarker(at: model.playhead) { NSSound.beep() } }
    @objc func menuRenameMarker(_ sender: NSMenuItem) {
        guard let t = (sender.representedObject as? NSNumber)?.int64Value else { return }
        beginRenameMarker(at: t)
    }
    @objc func menuRemoveMarker(_ sender: NSMenuItem) {
        guard let t = (sender.representedObject as? NSNumber)?.int64Value else { return }
        if !editor.removeMarker(near: t, tolerance: 0) { NSSound.beep() }
    }
}
