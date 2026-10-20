# Getting started

## Install

You need a Mac with Apple silicon (M1 or later) and macOS 14 Sonoma or later. Nothing
else: no Xcode, no Homebrew. Everything WizRec needs is inside the app.

1. Download the latest `WizRec-<version>.dmg` from
   [Releases](https://github.com/devswizard/wizrec/releases).
2. Open it and drag **WizRec** into **Applications**.
3. First launch only: right-click **WizRec** ▸ **Open** ▸ **Open**. WizRec is free and not
   notarized by Apple, so macOS asks once. If it only offers *Move to Trash*, open
   **System Settings ▸ Privacy & Security** and click **Open Anyway**.

Developers building from source: see the [README](../../README.md#build-from-source-developers).

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
