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
- Earlier sessions (RT-010, RT-016, RT-017, RT-020, RT-025, RT-026) for drag
  targets of panel tiles, transitions and the media bin.
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
| Media bin tile → **timeline** track | Lands at the drop point on that track; onto the empty area above the top track, a new track. Onto an occupied spot, nothing (non-magnetic) or an insert at a boundary (magnetic) | [obs] RT-020, RT-025 |
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
