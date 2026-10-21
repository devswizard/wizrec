// Accessibility audit of the library tiles for scripts/ui-checks (APP11-4; stands in for a
// manual VoiceOver pass). Walks the running app's accessibility tree through AXUIElement (needs
// Accessibility permission for the terminal, like System Events UI scripting).
//
//   swiftc -O ax-audit.swift -o ax-audit
//   ./ax-audit <pid> <window title part> <expected-ids file>
//
// The expected-ids file has one line per tile, "<tab title> <identifier>" (the app prints it
// with --print-library). For every library tab the tool selects the tab, scrolls its list from
// top to bottom collecting the tiles (elements whose AXIdentifier starts with "library."), and
// checks each tile:
//
//   - role: AXButton;
//   - label: non-empty AXTitle and AXDescription, unique among the tab's tiles;
//   - action: exposes AXPress;
//   - focus: AXFocused is settable, and setting it makes the tile the app's focused element;
//   - keyboard: Tab from a focused tile moves keyboard focus to another tile (key view loop);
//   - keyboard walk: Tab from the search field enters the grid, Tab visits every tile of the
//     tab once (tiles the lazy grid has not realized scroll into view), Tab from the last
//     tile leaves the grid, Shift-Tab from the first tile returns to the search field;
//
// and that every expected tile of the tab was found. Prints PASS/FAIL lines; exit status is
// the number of failures (capped at 125).
import ApplicationServices
import Foundation

let args = CommandLine.arguments
guard args.count >= 4, let pid = pid_t(args[1]) else {
    FileHandle.standardError.write(Data("usage: ax-audit <pid> <window title part> <expected-ids file>\n".utf8))
    exit(2)
}
let windowPart = args[2]
let expected: [(tab: String, id: String)] = ((try? String(contentsOfFile: args[3], encoding: .utf8)) ?? "")
    .split(separator: "\n").compactMap { line -> (tab: String, id: String)? in
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        return parts.count == 2 ? (parts[0], parts[1]) : nil
    }
let tabs: [String] = expected.reduce(into: [String]()) { if !$0.contains($1.tab) { $0.append($1.tab) } }

var failures = 0
/// Tiles Tab reached that the lazy grid had not realized when the walk started (all tabs).
var unrealizedReached = 0
func pass(_ s: String) { print("PASS \(s)") }
func fail(_ s: String) { print("FAIL \(s)"); failures += 1 }

// MARK: AX helpers

func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}
func string(_ e: AXUIElement, _ name: String) -> String { (attr(e, name) as? String) ?? "" }
func children(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func actions(_ e: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(e, &names) == .success else { return [] }
    return (names as? [String]) ?? []
}
func settable(_ e: AXUIElement, _ name: String) -> Bool {
    var ok: DarwinBoolean = false
    return AXUIElementIsAttributeSettable(e, name as CFString, &ok) == .success && ok.boolValue
}

/// Depth-first walk below `root` (depth-limited), calling `visit` on every element.
func walk(_ root: AXUIElement, depth: Int = 0, _ visit: (AXUIElement) -> Void) {
    guard depth < 40 else { return }
    for c in children(root) {
        visit(c)
        walk(c, depth: depth + 1, visit)
    }
}

func first(_ root: AXUIElement, where match: (AXUIElement) -> Bool) -> AXUIElement? {
    var found: AXUIElement?
    walk(root) { e in if found == nil, match(e) { found = e } }
    return found
}

func wait(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

/// Posts a key press (keyCode) to the app.
func key(_ code: CGKeyCode, shift: Bool = false) {
    for down in [true, false] {
        guard let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { continue }
        if shift { e.flags = .maskShift }
        e.postToPid(pid)
        wait(0.05)
    }
}

// MARK: Audit

guard AXIsProcessTrusted() else {
    fail("this process has no Accessibility permission (System Settings ▸ Privacy & Security ▸ Accessibility)")
    exit(1)
}
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 10)
_ = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
let windows = (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
guard let window = windows.first(where: { string($0, kAXTitleAttribute).contains(windowPart) }) else {
    fail("no window titled like \"\(windowPart)\" (windows: \(windows.map { string($0, kAXTitleAttribute) }))")
    exit(1)
}
_ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
_ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
wait(0.5)

func tiles(in root: AXUIElement) -> [AXUIElement] {
    var out: [AXUIElement] = []
    walk(root) { e in if string(e, kAXIdentifierAttribute).hasPrefix("library.") { out.append(e) } }
    return out
}

func focusedIdentifier() -> String {
    guard let f = attr(app, kAXFocusedUIElementAttribute) else { return "" }
    // swiftlint:disable:next force_cast
    return string(f as! AXUIElement, kAXIdentifierAttribute)
}

/// A tile's accessibility problems (role, title, description, press, focus) and its label.
func inspect(_ t: AXUIElement) -> (problems: [String], label: String) {
    let role = string(t, kAXRoleAttribute), title = string(t, kAXTitleAttribute)
    let desc = string(t, kAXDescriptionAttribute)
    var problems: [String] = []
    if role != kAXButtonRole { problems.append("role \(role.isEmpty ? "none" : role)") }
    if title.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("no AXTitle") }
    if desc.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("no AXDescription") }
    if !actions(t).contains(kAXPressAction) { problems.append("no AXPress (actions \(actions(t)))") }
    if !settable(t, kAXFocusedAttribute) { problems.append("AXFocused not settable") }
    return (problems, title.isEmpty ? desc : title)
}

/// The focused element for a log line: its identifier, or its role and title/description.
func focusedDescription() -> String {
    guard let f = attr(app, kAXFocusedUIElementAttribute) else { return "nothing" }
    let e = f as! AXUIElement   // swiftlint:disable:this force_cast
    let id = string(e, kAXIdentifierAttribute)
    if !id.isEmpty { return id }
    let label = [string(e, kAXTitleAttribute), string(e, kAXDescriptionAttribute)].first { !$0.isEmpty } ?? ""
    return label.isEmpty ? string(e, kAXRoleAttribute) : "\(string(e, kAXRoleAttribute)) \"\(label)\""
}

/// The scroll area holding `tile` (its nearest AXScrollArea ancestor).
func scrollArea(of tile: AXUIElement) -> AXUIElement? {
    var e: AXUIElement? = tile
    while let cur = e {
        if string(cur, kAXRoleAttribute) == kAXScrollAreaRole { return cur }
        e = attr(cur, kAXParentAttribute).map { $0 as! AXUIElement }   // swiftlint:disable:this force_cast
    }
    return nil
}

for tab in tabs {
    guard let button = first(window, where: {
        string($0, kAXRoleAttribute) == kAXRadioButtonRole
            && (string($0, kAXTitleAttribute) == tab || string($0, kAXDescriptionAttribute) == tab)
    }) else { fail("\(tab): no tab button"); continue }
    AXUIElementPerformAction(button, kAXPressAction as CFString)
    wait(1)

    // Collect every tile, scrolling the list from top to bottom (the grid is lazy).
    // Each tile is inspected while it is on screen: once the lazy grid scrolls it away, its
    // element is gone and reads as empty.
    var seen: [String: (problems: [String], label: String)] = [:]
    var order: [String] = []
    func collect() {
        for t in tiles(in: window) {
            let id = string(t, kAXIdentifierAttribute)
            if seen[id] == nil { order.append(id) }
            if seen[id] == nil || !string(t, kAXRoleAttribute).isEmpty { seen[id] = inspect(t) }
        }
    }
    collect()
    if let any = tiles(in: window).first, let area = scrollArea(of: any),
       let bar = attr(area, kAXVerticalScrollBarAttribute).map({ $0 as! AXUIElement }) {   // swiftlint:disable:this force_cast
        for step in 0...20 {
            AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, NSNumber(value: Double(step) / 20))
            wait(0.15)
            collect()
        }
        AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, NSNumber(value: 0.0))
        wait(0.3)
    }

    let want = expected.filter { $0.tab == tab }.map(\.id)
    let missing = want.filter { seen[$0] == nil }
    if missing.isEmpty { pass("\(tab): all \(want.count) tiles in the accessibility tree") }
    else { fail("\(tab): \(missing.count) of \(want.count) tiles not in the accessibility tree: \(missing.prefix(8))") }

    var labels: [String: [String]] = [:]
    var bad: [String] = []
    for id in order {
        guard let f = seen[id] else { continue }
        if !f.problems.isEmpty { bad.append("\(id): \(f.problems.joined(separator: ", "))") }
        labels[f.label, default: []].append(id)
    }
    if bad.isEmpty { pass("\(tab): \(order.count) tiles: AXButton, title + description, AXPress, focusable") }
    else { fail("\(tab): \(bad.count) tile(s) incomplete: \(bad.prefix(6).joined(separator: "; "))") }
    let dupes = labels.filter { $0.value.count > 1 }
    if dupes.isEmpty { pass("\(tab): labels unique") }
    else { fail("\(tab): duplicate labels: \(dupes.map { "\($0.key) ×\($0.value.count)" }.sorted().prefix(6))") }

    // Focus: setting AXFocused moves keyboard focus there; Tab then reaches another tile.
    let visible = tiles(in: window)
    guard let firstTile = visible.first else { fail("\(tab): no tile on screen to focus"); continue }
    let firstID = string(firstTile, kAXIdentifierAttribute)
    AXUIElementSetAttributeValue(firstTile, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    wait(0.3)
    if focusedIdentifier() == firstID { pass("\(tab): \(firstID) takes keyboard focus") }
    else { fail("\(tab): focusing \(firstID) left focus on \"\(focusedIdentifier())\"") }
    if visible.count > 1 {
        key(48)   // Tab
        wait(0.3)
        let next = focusedIdentifier()
        if next.hasPrefix("library."), next != firstID { pass("\(tab): Tab moves from \(firstID) to \(next)") }
        else { fail("\(tab): Tab from \(firstID) went to \"\(next)\", not to another tile") }
        key(48, shift: true)
        wait(0.3)
        if focusedIdentifier() == firstID { pass("\(tab): Shift-Tab returns to \(firstID)") }
        else { fail("\(tab): Shift-Tab went to \"\(focusedIdentifier())\"") }
    }

    // Keyboard walk (APP12-1): Tab from the search field enters the grid; Tab then visits
    // every tile of the tab once, including those the lazy grid had not realized (they scroll
    // into view); Tab from the last tile leaves the grid; Shift-Tab from the first tile
    // returns to the search field.
    guard let search = first(window, where: { string($0, kAXIdentifierAttribute) == "librarySearch" }) else {
        fail("\(tab): no search field (librarySearch)"); continue
    }
    let realizedAtTop = Set(tiles(in: window).map { string($0, kAXIdentifierAttribute) })
    func focusSearch() {
        AXUIElementSetAttributeValue(search, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        wait(0.3)
    }
    focusSearch()
    if focusedIdentifier() != "librarySearch" {
        fail("\(tab): focusing the search field left focus on \"\(focusedIdentifier())\""); continue
    }
    key(48)
    wait(0.4)
    let entry = focusedIdentifier()
    guard entry.hasPrefix("library.") else {
        fail("\(tab): Tab from the search field went to \"\(entry)\", not to a tile"); continue
    }
    pass("\(tab): Tab from the search field enters the grid at \(entry)")
    var visited: [String] = [entry]
    var leftTo = ""
    for _ in 0..<(want.count + 2) {
        key(48)
        wait(0.4)
        let f = focusedIdentifier()
        if !f.hasPrefix("library.") || visited.contains(f) { leftTo = f; break }
        visited.append(f)
    }
    let visitedSet = Set(visited)
    let notReached = want.filter { !visitedSet.contains($0) }
    if notReached.isEmpty, visited.count == want.count {
        let offscreen = visited.filter { !realizedAtTop.contains($0) }.count
        unrealizedReached += offscreen
        pass("\(tab): Tab visits all \(want.count) tiles once (\(offscreen) not realized at the start)")
    } else {
        fail("\(tab): Tab visited \(visited.count) of \(want.count) tiles; not reached \(notReached.prefix(6)); stopped at \"\(leftTo)\"")
    }
    let lastTile = visited.last ?? entry
    if leftTo == lastTile {
        fail("\(tab): Tab from the last tile \(lastTile) left focus there")
    } else if leftTo.hasPrefix("library.") {
        fail("\(tab): Tab from the last tile \(lastTile) went back to tile \(leftTo)")
    } else {
        pass("\(tab): Tab from the last tile \(lastTile) leaves the grid (to \(focusedDescription()))")
    }
    // Back at the top: Shift-Tab from the first tile goes to the search field.
    focusSearch()
    key(48)
    wait(0.4)
    if focusedIdentifier() == entry {
        key(48, shift: true)
        wait(0.4)
        let back = focusedIdentifier()
        if back == "librarySearch" { pass("\(tab): Shift-Tab from the first tile \(entry) returns to the search field") }
        else { fail("\(tab): Shift-Tab from the first tile \(entry) went to \"\(back)\", not to the search field") }
    } else {
        fail("\(tab): Tab from the search field went to \"\(focusedIdentifier())\" the second time, not \(entry)")
    }
}

// The walk must have crossed the lazy grid's edge somewhere (the check runs a small window).
if unrealizedReached > 0 { pass("Tab reached \(unrealizedReached) tile(s) the lazy grid had not realized") }
else { fail("every tile was realized from the start: the walk never crossed the lazy grid's edge (window too tall?)") }

print(failures == 0 ? "ax-audit: all checks passed" : "ax-audit: \(failures) failure(s)")
exit(Int32(min(failures, 125)))
