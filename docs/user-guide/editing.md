# Editing

Every change is undoable (⌘Z / ⇧⌘Z) and is written to the project in Camtasia's own format.

## Timeline basics

- **Tracks** stack bottom to top: higher tracks draw over lower ones. Track headers have
  mute, hide and lock buttons. Timeline ▸ Add Track adds one.
- **Playhead:** click the ruler or drag the playhead. ←/→ step one frame, ⇧←/⇧→ one second.
- **Zoom:** ⌘= / ⌘- / ⌘0 (fit).
- **Snapping** (Timeline ▸ Snapping): moves and trims snap to clip edges, the playhead and
  markers.

## Clips

| Task | How |
|---|---|
| Move | Drag. Drop on another track to change track |
| Trim | Drag the left or right edge. Trims stop at the end of the source media |
| Split | Put the playhead on the clip and press S |
| Delete | ⌫. ⇧⌫ ripple-deletes (later clips move left to close the gap) |
| Ripple move or trim | ⌥-drag |
| Copy / paste | ⌘C / ⌘V |
| Speed | Clip ▸ speed in the Properties panel. A badge on the clip shows the speed |
| Extend frame | Timeline ▸ Extend Frame holds a frame for longer |
| Separate audio | Clip ▸ Separate Video and Audio |

## Groups and stitched clips

- **Group** (⌘G) several clips into one clip you can move and animate as a unit;
  **Ungroup** with ⇧⌘G.
- **Double-click** a group to edit inside it; Esc goes back up.
- **Stitch** (Clip ▸ Stitch Selected Media) joins adjacent clips from the same source into
  one seamless clip; **Unstitch** splits it again.

## Markers

Press M to add a marker at the playhead. Drag a marker to move it; double-click to rename it.

## Effects and transitions

Drag an effect from the library onto a clip, or a transition onto the cut between two
clips (or onto a clip's start or end for a fade in/out). Remove them from the clip's
context menu. See [Library](library.md).

## Properties

Select a clip to edit position, scale, rotation, opacity and crop in the Properties panel.
Effects added to the clip appear there with their settings.
