# Recording

Choose File ▸ New Recording (⌘R). The recorder panel opens.

## Sources

- **Screen:** a whole display, a window, or a region you drag out (Esc cancels the selection).
- **Camera:** any connected camera, recorded to its own file.
- **Microphone** and **system audio:** each recorded to its own track, so you can adjust or
  mute them separately later.
- **Cursor:** the pointer is *not* burned into the screen video. WizRec logs its position,
  shape and clicks, and draws it as a separate layer. That is what lets you enlarge,
  highlight, smooth or hide the cursor after recording, and add click effects.
- **Keystrokes:** optional, only after you allow it. Used for keystroke callouts.

## Controls

| Action | How |
|---|---|
| Start | The record button, or ⇧⌘2 from any app. A short countdown runs first |
| Pause / Resume | ⇧⌘P |
| Stop | ⇧⌘2 again, or the stop button |

When you stop, the recording is saved in the project under `recordings/<date-time>/` and
placed on the timeline as one undoable step.

## Troubleshooting

- **Black or empty video:** grant Screen & System Audio Recording to WizRec in System
  Settings ▸ Privacy & Security, then quit and reopen WizRec.
- **No system audio:** the same permission covers system audio on macOS 15 and later.
- **Stale entries:** earlier prototypes used the same name; remove old WizRec entries from
  the permission list if the toggle seems to have no effect.
