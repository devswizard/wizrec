import AppKit

// Inline renaming of timeline markers: a text field over the ruler; Return commits
// (RenameMarker), Esc or clicking away without changes cancels.
extension TimelineCanvas: NSTextFieldDelegate {
    func beginRenameMarker(at time: Int64) {
        endRenameMarker(commit: false)
        guard let m = snapshot.markers.first(where: { $0.time == time }) else { return }
        let L = layout
        let x = min(max(L.x(ofTicks: time) + 6, L.clipArea.minX), max(L.clipArea.minX, bounds.maxX - 160))
        let field = NSTextField(frame: CGRect(x: x, y: max(0, L.metrics.rulerHeight - 22), width: 150, height: 20))
        field.stringValue = m.name
        field.placeholderString = "Marker name"
        field.font = .systemFont(ofSize: 11)
        field.focusRingType = .none
        field.bezelStyle = .roundedBezel
        field.delegate = self
        addSubview(field)
        markerEditor = (field, time)
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    /// Ends renaming; with `commit`, applies the field's text. Returns whether a rename happened.
    @discardableResult
    func endRenameMarker(commit: Bool) -> Bool {
        guard let (field, time) = markerEditor else { return false }
        markerEditor = nil
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.delegate = nil
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
        needsDisplay = true
        return commit ? editor.renameMarker(at: time, to: name) : false
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            endRenameMarker(commit: true); return true
        case #selector(NSResponder.cancelOperation(_:)):
            endRenameMarker(commit: false); return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // Focus left the field (click elsewhere): keep what was typed.
        if markerEditor != nil { endRenameMarker(commit: true) }
    }
}
