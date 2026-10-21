# Spec: the editor's main-window workflow (UX checklist)

What a user of Camtasia 2026.2.3 meets in the main window, described in our
own words, so WizRec's app work can check it covers the same jobs. This is a
**checklist of jobs and entry points**, not a design: WizRec's look, layout,
wording and icons are its own. No screenshots, icons or UI text were copied;
feature names are given only where a project file or a user's habit depends
on them.

Tags: **[obs]** observed in the running app, **[inf]** inferred, **[?]**
unknown.

## Evidence base

- **UI1 (RT-027, session 10).** Camtasia launched with no document, then
  *File ▸ New Project*, then a copy of `format/video-photo-base` (one 10 s
  video on track 1, one 5 s photo on track 2) opened from
  `camtasia_rea_refs/research/ui14/`. Read through the accessibility tree
  (roles, labels, tooltips, enabled state, frames), menus listed, three
  media-bin drops onto the canvas saved (`ui1`–`ui3`). Window at
  1466×949 pt [obs].
- Earlier sessions (RT-010, RT-016, RT-017, RT-020, RT-025, RT-026) and
  RT-028 (drops onto busy spots) for drag targets of panel tiles,
  transitions and the media bin.
- Not studied: account, plan and purchase controls, sign-in, the trial
  export gate and the recorder window (permission-bound). Nothing
  licensing-related was opened.

## 1. Start screen (no document open)

Camtasia opens a separate **welcome window** when no project is open; it is
also reachable later from *File ▸ Home* and from a house button at the left
of the editor toolbar [obs].

| What it offers | Tag |
|---|---|
| A short greeting headline, then one row of large tiles: **New Recording**, **New Project**, **Open Project**, then (after a divider) shortcuts to companion products: image capture, AI script writing, collaboration | [obs] |
| **Recent projects** strip: one card per project with a canvas thumbnail, the project name, the date and the bundle size, and the duration overlaid on the thumbnail; scrolls sideways. A second tab beside it shows **templates** | [obs] |
| An **asset store** strip lower down (featured / free / premium tabs) rendered as web content: marketing tiles for downloadable templates and backgrounds | [obs] |
| A left sidebar: Home, Learn (tutorials), Support, What's New; below it an account card | [obs] (account card not studied) |
| Opening a project or making a new one opens an editor window and **keeps the welcome window open behind it** (the Window menu lists both) | [obs] |
| Cards open on click; recent projects are the same list as *File ▸ Open Recent* | [inf] |

For WizRec (checklist, [inf]): New Recording, New Project, Open Project and
Recent projects (thumbnail, name, date, duration) are the first-time user's
four jobs. Templates and an asset store are optional; companion-product and
account tiles have no WizRec equivalent.

## 2. Editor window layout

One window per project, four regions [obs]:

```
┌ toolbar: home · record ▾ ······ canvas tools · zoom % ······ help · downloads · account · Export ┐
├ tab rail │ tools panel │            canvas            │ properties panel ┤
│ (icons + │ (content of │  transport: prev/next frame, │ (selected item,   │
│  labels) │  the tab)   │  play, prev/next clip, scrub │  tabs at top)     │
├──────────┴─ timeline toolbar: undo redo cut copy paste split frame … zoom ─ detach · meter ┤
│ track headers │ ruler + playhead + tracks                                                     │
└───────────────┴───────────────────────────────────────────────────────────────────────────────┘
```

| Claim | Tag |
|---|---|
| Left: a **vertical tab rail** (icon + label per tool) and, beside it, the **tools panel** showing the chosen tab. Both can be hidden (*View ▸ Show Tools Panel*) | [obs] |
| Centre: the **canvas** with a transport row under it: previous frame, play/pause, next frame, previous/next clip, a scrub slider, and a `current/total` time label in `hh:mm:ss;ff` | [obs] |
| Right: the **properties panel** for the selection, toggled by a *Properties* button under it | [obs] |
| Bottom: the **timeline**, separated by a draggable splitter; it can be detached into its own window | [obs] |
| The canvas can also be detached (*View ▸ Canvas ▸ Detach Canvas*) | [obs] |
| A new project starts with **two empty tracks**, named by number | [obs] |

## 3. Main toolbar (top of the editor)

Left to right [obs]:

| Control | What it does | Tag |
|---|---|---|
| Home (house) | Opens the welcome window (recent projects etc.) | [obs] |
| **Record** + a small chevron | Record opens the screen recorder. The chevron opens a flyout of recording kinds: video/audio (screen), audio only and image; the last two launch companion products | [obs] (recorder itself not opened) |
| Canvas tool group (five toggles, centre) | Edit (move/rotate/resize), corner pin (perspective), pan the view, crop, auto-animate (edits on the canvas write animations). See §8 | [obs] tooltips |
| Canvas zoom menu (shows the current %, e.g. 74 %) | Fit, fixed steps 25 %–2000 %, Center Canvas, Detach Canvas, and *Project Settings…* | [obs] |
| Help toggle | Turns on in-app tip markers | [obs] |
| Downloads | Asset download progress | [obs] |
| Account | Account menu | [obs] (not studied) |
| **Export** (a wide, highlighted button at the far right) | Starts making a shareable video from the timeline | [obs] tooltip; the click was not made (trial gate, RT-001) |

For WizRec (checklist, [inf]): Record and Export are the two primary
actions and sit at opposite ends; canvas mode tools and zoom sit in the
middle. Undo/redo/split live in the **timeline** toolbar, not here.

## 4. Drag-and-drop targets

| Source → target | Result | Tag |
|---|---|---|
| Media bin tile → **canvas** | Adds the clip (one undoable add step) at the **playhead**, on the **lowest track with room for the whole clip** from the playhead; if none has room, a **new track on top**. Seen three times: playhead 0 with tracks 1–2 busy → new track 3; playhead 7 s → track 2 (free from 5 s, while track 3 was also free); playhead 5.5 s → track 3, because track 2 had only 1.5 s free before its next clip | [obs] `ui1`–`ui3`; rule [inf] from 3 cases |
| Media bin tile → **timeline** track | Lands at the drop point on that track; onto the empty area above the top track, a new track. Onto an occupied spot: at or just after a clip's start, an insert that pushes that track's later clips; elsewhere, the lowest higher track with room; with no room, refused (`group-edits.md` §8.7) | [obs] RT-020, RT-025, RT-028; the no-room case [inf] |
| Annotation / callout tile → canvas | New callout, 5 s, at the playhead | [obs] RT-017 |
| Visual / audio / cursor effect, behaviour, animation tile → a clip (timeline or canvas) | Adds that item to the clip | [obs] RT-010, RT-016 |
| Transition tile → a clip edge or a cut | One- or two-sided transition | [obs] RT-016 |
| Assets panel grid tile → canvas | Downloads and adds it (new top track, at the playhead) | [obs] RT-026 |
| Dynamic caption style tile → timeline (an audio clip) | Transcribes and adds a caption callout (the panel's own two-step help says so) | [obs] panel text; RT-012 (menu route) |
| Files from Finder → media bin, canvas or timeline | Imports them (the Media tab's tooltip says media can be added from the computer and dragged onto the timeline or canvas) | [inf] (Finder drags not automated) |
| Media bin tile → its own context menu | **None**: bin tiles open no context menu | [obs] RT-025, UI1 |

For WizRec (checklist, [inf]): accept drops on all three surfaces (bin,
canvas, timeline). A canvas drop is "add at playhead, first free track
upwards, else a new top track"; a timeline drop is "add where dropped".

## 5. Empty states

| Where | What a first-time user sees | Tag |
|---|---|---|
| Media bin, no media | A sentence saying recordings and imported media appear here, and an **import** button in the middle of the panel | [obs] |
| Library, empty | A sentence saying the library is empty and holds media reusable across projects, plus the same import button | [obs] |
| Properties, nothing selected | A heading saying nothing is selected, and a hint to select something on the timeline | [obs] |
| Canvas, empty project | Just the canvas background colour (black by default) at the project size; no hint text | [obs] |
| Timeline, empty project | Two empty, named tracks; the playhead at 0; time label `00:00:00;00/00:00:00;00` | [obs] |
| Transport and edit buttons, empty project | Play, frame step and clip step are disabled; Undo, Redo, Cut, Copy and Split are disabled; **Paste stays enabled** | [obs] |
| With media but no selection | Play and next frame/clip enable; Split stays disabled until a clip is selected **and** the playhead is over it | [obs] (selected clip at playhead 0, its start: still disabled) [inf] for the rule |
| Transitions tab, empty project | Tiles are shown dimmed (disabled) | [obs]; that they enable once clips exist [inf] |
| Favorites tab, nothing favourited | An empty grid with only a type filter | [obs] |
| Captions tab | A short numbered how-to: drag a style onto the timeline to generate captions, then select the audio to edit them | [obs] |

For WizRec (checklist, [inf]): every empty panel says what goes there and
offers the one action that fills it (Import, Record, drag a style).

## 6. Tools panel (left), tab by tab

Twelve tabs on the rail, top to bottom. Each tab is a grid of tiles with a
search field and/or a type filter at the top. Tiles are used by
**dragging them onto a clip, the canvas or the timeline** (§4). The same
list is in *View ▸ Tools* [obs].

| Tab | What it holds | Notes | Tag |
|---|---|---|---|
| Favorites | Tiles the user starred in other tabs, filterable by type | Empty at first | [obs] |
| Media | Three segments: the project's **media bin**; an **online assets** browser (rows of titles, stock footage, callouts, animated backgrounds and music, each with a see-all grid; some items marked premium); and the user's **library** (assets reused across projects, with a library picker and search) | The bin has a sort pop-up (media type, name, date added, date created, dimensions, duration) with ascending/descending toggles, a view switch and an add button (import media, import from a meeting service). Tiles sit under alphabetical headings | [obs] |
| Annotations | Six sub-tabs: callouts (bubbles, plain text), arrows and lines, shapes, blur and highlight (blur, pixelate, spotlight, highlighter), sketch motion (draw-on), keystroke callouts. Style and theme pop-ups at the top | Format: `callouts.md` | [obs] |
| Transitions | One searchable grid of named transitions, with a type filter | Dimmed in an empty project | [obs] |
| Visual Effects | Two sub-tabs: effects (background removal, blend mode, blur region, border, clip speed, colour adjustment, tint, colourize …) and colour **filters** (looks) | `effects/catalog.md` | [obs] |
| Animations | Preset zoom/opacity/tilt/scale moves, a custom animation, motion path, automatic focus | `animation.md` | [obs] |
| Behaviors | Behaviour presets for text and media (drifting, explode, fade, fly in …) | `behaviors.md` | [obs] |
| Cursor Effects | Three sub-tabs: cursor (colour, glow, highlight, isolation, magnify, motion blur, path creator, shadow …), left-click and right-click effects (rings, ripples, sound …) | Only usable on screen recordings with cursor data: on a plain video they are disabled in the canvas menu | [obs] |
| Audio Effects | Noise removal, compression, captions, clip speed, emphasize, fade in/out, pitch | `audio.md` | [obs] |
| Narration | Microphone picker, input level, an option to mute the speakers while recording, a start button; below, AI voice generation and AI script writing | Voice-over recording | [obs] |
| Gesture Effects | Tap, double tap, pinch, swipe, tap and hold (for mobile demos) | | [obs] |
| Captions | Dynamic caption style tiles with a short how-to, and a transcription section | `captions.md` | [obs] |

For WizRec (checklist, [inf]): a first-time user needs Media (bin and
import), Annotations, Transitions, Visual Effects, Animations, Cursor
Effects, Audio Effects and Captions. Favorites, an online asset store,
gesture effects and AI narration can come later or stay out of scope.

## 7. Main menus, grouped by purpose

Not a transcript: the groups say which jobs the menus cover [obs].

| Purpose | Where | What is there |
|---|---|---|
| Project files | File | New, open, open recent, new from template, close, save, save as, save as template, revert; the welcome window |
| Bring media in | *File ▸ Import* | Media, captions, zipped project, template, package, a meeting-service import |
| Get media out | *File ▸ Export* and the Export menu (same items) | Local file, two online services, audio only, **a frame as an image**, captions, batch export, export history. *File ▸ Export* adds project-for-Windows, template and package |
| Record | File | New recording, new narration, connect a mobile device; launchers for two companion apps |
| Library | *File ▸ Library* | Import/export the library or single assets, expand/collapse |
| Clipboard and selection | Edit | Undo/redo, cut/copy/paste/delete, **ripple cut and ripple delete**, duplicate; select (all, preceding/succeeding, to the start/end of a clip, everything left/right, transitions, everything at the playhead), deselect; copy/paste effects; copy/paste properties |
| Cutting | Edit | **Split**, split all tracks at the playhead, stitch selected, separate audio and video; playhead commands (extend frame to the playhead, trim start/end to the playhead, add the exported frame) |
| Audio | Edit | Silence/restore audio, sync media, add an audio point, a hand-off to a companion app |
| Arranging | Edit | Group, ungroup, resize a group (to the canvas, to the visible size, custom), stacking order, placeholders |
| Navigation | *Edit ▸ Jump To* | Beginning/end, 15 frames forward/back, a typed time, next/previous clip, animation, marker, quiz |
| Canvas framing | Edit | Zoom-and-pan; pan here; scale to 200/100/50/25 %, fit, fill |
| Project | *Edit ▸ Project Settings…* | Canvas size (presets from small social sizes up to 4K, square and vertical, fit to visible, custom; width/height with an aspect lock), background colour, frame rate (25/30/50/60 in this project), automatic loudness normalisation |
| Clip changes | Modify | Duration; add animation, behaviour, effects (visual, audio, cursor, gesture), filter; **remove** (stitches, animations, audio points, transitions, each kind of effect, clip speed, everything); captions add/remove; dynamic caption style; markers (add a timeline marker, remove all); quizzes |
| Text | Text | Edit text, bold/italic/underline, alignment, copy/paste style |
| Panels and view | View | Show the tools panel, each tool tab, properties, markers, quizzes, transcript, caption track; canvas zoom (in, out, fit, 100 %, centre, preview outside a group, detach/attach); timeline zoom (in, out, fit, to selection, maximum), track heights, detach; **open/close group**; canvas and timeline **snapping**; rulers; timeline display (thumbnails, waveforms, names); captions in the preview; full-screen preview |
| App | App menu | Settings, themes, templates, account, updates |
| Help | Help | Online help, quick start, tutorials, support, feedback, **keyboard shortcuts** |

## 8. Canvas tools

| Tool | Behaviour | Tag |
|---|---|---|
| Edit (default) | Select, move, rotate and resize media on the canvas; edit text | [obs] tooltip |
| Corner pin | Drag the corner points for a perspective look | [obs] tooltip |
| Pan | Drag the view around; the project doesn't change | [obs] tooltip |
| Crop | Trim the edges of the selected media on the canvas; also reachable from the canvas context menu | [obs] |
| Auto-animate | While on, canvas edits write animations at the playhead instead of constant changes | [obs] tooltip; file effect [inf] (`animation.md`) |
| Zoom menu | Fit, 25 %–2000 %, centre, detach; *View ▸ Canvas* adds zoom in/out and 100 % | [obs] |
| Snapping | *View ▸ Enable Canvas Snapping*; optional rulers | [obs] |
| Canvas context menu (on a clip) | Cut, copy, duplicate, delete; scale (fit, fill, actual pixels, 200/100/75/50/25 %); stacking order; group; add effects (every visual, audio, cursor and gesture effect, and filters); hide properties; copy properties; crop mode; project settings | [obs] |

### 8.1 Canvas handles in Edit mode (RES15-2, RT-031)

Save-only gestures on a 1600×900 still at scale 1 on a 1920×1080 canvas,
canvas zoom 74 % (1 pt on screen = 2.697 canvas px), canvas snapping
**off** unless noted. Each gesture started from the same state (undone
after saving). Drags were synthetic mouse events with modifiers held.
Translation is in canvas px, +y up (`transform.md` §1).

| Gesture | Result in the saved project | Tag |
|---|---|---|
| Drag inside the media (centre or elsewhere) | Move: `translation0/1` change by the drag; nothing else | [obs] |
| Drag a **corner** handle | **Uniform** scale (`scale0` = `scale1`); the **opposite corner stays fixed**; the scale follows the axis with the larger relative change (+80.9 px on both axes of 1600×900 → 1.0899, the height ratio) | [obs] |
| **Shift** + corner | Free scale: each axis follows the pointer (1.0506 × 1.0899), opposite corner fixed | [obs] |
| Drag an **edge** handle (middle of a side) | **Uniform** scale from that axis; the **opposite edge stays fixed**, the other axis grows equally on both sides (right edge +80.9 px → scale 1.0506 both, `translation0` +40.45, `translation1` 0) | [obs] |
| **Shift** + edge | Stretch that axis only (`scale0` or `scale1` alone), opposite edge fixed | [obs] |
| **Option** + corner or edge | No change saved | [obs] (what Option does on the canvas is [?]) |
| Handle hit area | About ±4 pt around the edge: 2 pt inside the right edge grabbed the handle, 6 pt inside moved the media, 6 pt outside did nothing | [obs] |
| Rotation handle | **None found**: drags 10–76 pt above the top edge, 7–18 pt beyond a corner, 8 pt below centre and below the bottom edge (with a 1.2 s hover first) changed nothing or moved the media. Rotation is set in Properties (Z/Y/X dials) [obs]; an on-canvas rotate gesture is [?] | [obs] negative |
| The lock in Properties *Size* | Read as unchecked (value 0) while corners still scaled uniformly, so it is not "corner keeps aspect" [obs]; whether turning it on/off changes the handle rules is [?] | |
| First transform gesture on a clip | Writes `metadata.default-translation0/1/2`, `default-scale0/1/2`, `default-rotation0/1/2`, `default-anchor0/1/2`, `default-shear0/1/2`, `default-width`, `default-height` (the values before the edit); render-neutral | [obs] |

**Snapping** (*View ▸ Enable Canvas Snapping*, on by default):

| Claim | Tag |
|---|---|
| With snapping on, a corner drag that brought the bottom edge 4 px short of the canvas bottom ended **exactly on it** (scale 1.1, bottom = −540) | [obs] one case |
| With snapping off the same drag gave 1.0899 | [obs] |
| Snap distance, the other snap targets (centre lines, other media) and the guide lines drawn are [?] | |

**Crop mode** (*toolbar crop tool*, or *crop mode* in the canvas context
menu): the gestures and the keys a crop writes are **[?]**. Camtasia
stopped answering accessibility requests right after the crop tool was
pressed by automation, so no crop save was made this session.
`transform.md` §6 keeps the existing `geometryCrop*`/`sourceCrop*` model.

Transport under the canvas: previous frame, play/pause, next frame,
previous/next clip, a scrub slider and the time label. Buttons that can't
act are disabled, not hidden [obs].

## 9. Timeline tools

| Element | Behaviour | Tag |
|---|---|---|
| Timeline toolbar, left | Undo, redo, cut, copy, paste, split, add exported frame; each tooltip shows the shortcut | [obs] |
| Timeline toolbar, centre | Zoom to fit (all media in view), zoom out, a zoom slider, zoom in | [obs] |
| Timeline toolbar, right | Detach the timeline; an audio meter toggle (a level meter with a peak readout and an output-level slider) | [obs] |
| A wide unlabelled button after add-frame, disabled in every state seen | — | [?] |
| Ruler and playhead | The playhead carries **left and right range handles** for selecting a time range | [obs] (element names); how ranges are used [inf] |
| Above the track headers | **Add a track**; a toggle for a tray above the timeline showing quizzes, markers or the transcript; a slider for all track heights | [obs] |
| Caption track header | A menu: remove captions, hide the caption view, transcribe the selected media, flag durations that break caption guidelines, caption language, caption settings | [obs] |
| Track header | The track name and three buttons: **lock**, **disable** (hidden from preview and export; Option-click solos the track), **magnetic**. An edge handle sets the track height | [obs] |
| Track header context menu | Add a placeholder, insert a track above/below, move the track (top, up), remove, rename, turn off, solo, lock, magnetic, detach the timeline, minimise/maximise | [obs] |
| Empty track area context menu | The track-header items without minimise/maximise | [obs] |
| Clip context menu | Cut, copy, delete, ripple cut, ripple delete, hide properties, select in media bin, copy/paste properties, group, colour label (seven colours), add clip speed, update media, convert to placeholder, add to library | [obs] |
| Clip look | Name and thumbnails; *View ▸ Display* picks thumbnails, waveforms, names | [obs] |
| Snapping | *View ▸ Enable Timeline Snapping* | [obs] |
| Markers | *Modify ▸ Markers ▸ Add Timeline Marker*; shown in the tray above the timeline | [obs] (`markers.md`) |
| Magnetic tracks | Track-header button or context menu | [obs] (`edit-semantics.md` ED3) |

## 10. Properties panel (right)

| Claim | Tag |
|---|---|
| Nothing selected: a heading saying so, and a hint | [obs] |
| A selected video shows a heading with the clip name (a double-click collapses it), a reset-all button and tabs along the top. For the silent test video only the visual tab was present | [obs] |
| Visual tab: scale and opacity (slider and field each), rotation X/Y/Z (dial and field), position X/Y/Z, size width/height with an aspect lock, skew (slider and field) | [obs] |
| Each applied effect adds its own section with its parameters | [obs] RT-003 |
| Fields take typed values; clicking a changed value's label resets it | [obs] (tooltip of a rotation label) |

## 11. Record and export entry points

| Job | Entry points | Tag |
|---|---|---|
| Record the screen | Welcome tile; toolbar Record; *File ▸ New Recording…*; the toolbar flyout, which shows a global shortcut | [obs] |
| Record a voice-over | Narration tab; *File ▸ New Narration…* | [obs] |
| Other capture kinds | Toolbar flyout: audio only and image capture (companion apps); *File ▸ Connect Mobile Device…* | [obs] |
| Export a video | Toolbar Export (far right); the Export menu; *File ▸ Export* | [obs] (dialogs not opened: trial gate, RT-001) |
| Export a frame, audio only or captions | Export menu items | [obs] |
| Export several projects | *Export ▸ Batch Export…* | [obs] |
| Put a still of the current frame on the timeline | Timeline toolbar button; *Edit ▸ Playhead ▸ Add Exported Frame at Playhead* | [obs] |

## 12. First-time user path (priority checklist for WizRec)

Ordered by what a new user meets first [inf, from §1–§11]:

1. Start screen: record, new, open, recent projects.
2. An empty editor that explains itself: the bin's import button and
   hint, the properties hint, two empty tracks.
3. Import by button, menu or a drag from Finder; media shows in the bin.
4. Drag from the bin to the canvas (placed at the playhead) or to the
   timeline (placed where dropped).
5. Play, scrub, step frames; the time label.
6. Select a clip; change position, scale, rotation and opacity in
   properties or on the canvas.
7. Split at the playhead, trim, delete or ripple delete, undo/redo: all in
   the timeline toolbar and the clip context menu.
8. Add an annotation, transition, effect or animation by dragging a tile.
9. Captions: add or generate them, then edit.
10. Export through one prominent button, and save.

Later: groups, magnetic tracks, markers, cursor effects, templates and a
library, a detachable canvas and timeline, snapping toggles, track solo
and lock.
