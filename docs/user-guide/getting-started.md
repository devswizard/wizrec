# Getting started

## Install

- **Release:** open the `WizRec-<version>.dmg` and drag WizRec to Applications. Releases run
  on Apple silicon Macs with macOS 14 or later.
- **From source:** see the [README](../../README.md#build-from-source). A source build uses
  Homebrew's FFmpeg, so keep `brew install ffmpeg` on that Mac.

## Permissions

macOS asks for these the first time a feature needs them. You can change them later in
System Settings ▸ Privacy & Security.

| Permission | Needed for |
|---|---|
| Screen & System Audio Recording | Recording the screen or a window, and system audio |
| Camera | Recording your webcam |
| Microphone | Recording your voice |
| Accessibility (or Input Monitoring) | Logging keystrokes for keystroke callouts; off unless you turn it on |

WizRec records locally. It does not upload anything.

## The editor window

```
┌──────────────┬─────────────────────────────────┬──────────────┐
│ Media bin    │ Canvas (preview)                │ Properties   │
│ + Library    │                                 │ (inspector)  │
├──────────────┴─────────────────────────────────┴──────────────┤
│ Timeline: tracks, clips, playhead, markers                    │
└────────────────────────────────────────────────────────────────┘
```

- **Media bin:** the project's sources. Drag files in from Finder, or use File ▸ Import Media (⌘I).
- **Canvas:** the frame at the playhead, drawn exactly as it will export.
- **Properties:** position, scale, rotation, opacity, crop, speed and effect settings of the
  selected clip. Changes are undoable.
- **Timeline:** see [Editing](editing.md).

## First project

1. File ▸ New Project (⌘N), or File ▸ Open (⌘O) to open an existing `.cmproj`.
2. Import media or make a recording (File ▸ New Recording, ⌘R).
3. Drag media from the bin onto a track.
4. Press Space to play.
5. Save (⌘S). WizRec keeps the previous version as `project.tscproj.wizrec-backup` inside
   the project package.
