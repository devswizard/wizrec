<!--
  Release notes used by .github/workflows/release.yml for the draft GitHub Release.
  Written for v0.1.1 (v0.1.0's notes are in git history and on its GitHub Release).
  For a later release: rewrite "What's new", update "Known limits", and change the
  version in the download line and the tag in the links (v0.1.1) before tagging.
  See docs/RELEASING.md.
-->

A bug-fix and polish release of **WizRec**, the free, open-source screen recorder and
video editor for the Mac by Devs Wizard. It opens your Camtasia projects.

## Download

Download **WizRec-0.1.1.dmg** below. Nothing else to install: FFmpeg and everything
WizRec needs are inside the app.

**You need:** a Mac with Apple silicon (M1 or later) and macOS 14 Sonoma or later.

1. Open the DMG and drag **WizRec** into **Applications**. If you have WizRec 0.1.0,
   quit it first and choose **Replace**: your projects and settings stay as they are.
2. First launch only: in Applications, right-click (or Control-click) **WizRec** and
   choose **Open**, then click **Open** in the dialog. macOS asks this once because
   WizRec is not notarized by Apple.
3. If macOS only offers *Move to Trash* or *Done*: open **System Settings ▸ Privacy &
   Security**, scroll down to the message about WizRec and click **Open Anyway**, then
   confirm with your password or Touch ID.

To record, allow WizRec under **System Settings ▸ Privacy & Security** for
**Screen & System Audio Recording**, **Camera** and **Microphone** when macOS asks.

`SHA256SUMS.txt` lists the checksum of the DMG. To check your download:
`shasum -a 256 -c SHA256SUMS.txt` in the folder that holds both files.

## What's new

**Fixes**
- **Export and recording no longer hang.** When macOS's video encoder stops responding,
  an export now stops with the message "The encoder stopped responding" in the export
  queue, and a recording ends with an error, instead of waiting forever. The unfinished
  file is removed.
- **The window stays responsive** while the preview renders a snapshot: WizRec no
  longer waits for the graphics card on the main thread.
- **Captions typed in Camtasia** (saved as rich text) now show their text in WizRec
  instead of raw formatting codes.

**Editing, closer to Camtasia**
- **Copy and paste with groups** works the way Camtasia does it: clips copied out of a
  group keep their place and size on the canvas, and clips pasted into a group stay
  inside the group's time range (on a free track inside it) instead of making the group
  longer. Copying from or pasting into a Rev media group is not allowed, as in Camtasia.
- **Animated shader backgrounds**: keyframes you set on a background's settings are now
  saved the way Camtasia saves them, so the animation survives a later move or resize
  of the clip.

**Accessibility**
- The tiles on every **Library** tab can be reached with the keyboard: **Tab** and
  **Shift-Tab** move between tiles, **Space** or **Return** acts like a click on the
  focused tile, and VoiceOver reads each tile's name. Space on a
  focused tile no longer starts playback.

**Download and app bundle**
- The app no longer carries file paths from the machine that built it, and every
  release is checked for that before it goes public.
- Groundwork for automatic updates (see Known limits).

## Known limits

- **Not notarized.** WizRec is signed ad hoc, not with an Apple Developer ID, so macOS
  asks before the first launch (see above).
- **No automatic updates yet.** The built-in updater is still switched off; it turns on
  in a later release. Watch [Releases](https://github.com/devswizard/wizrec/releases)
  for new versions.
- **Backgrounds in Camtasia.** Camtasia does not show WizRec's own animated backgrounds
  when it opens a project saved by WizRec (it accepts only its own). WizRec warns when
  you save such a project. Everything else in the project opens in Camtasia.
- **Look may differ slightly from Camtasia.** Effects, transitions, callouts, cursor
  effects and easing are built from the project files and observation, but have not yet
  been compared frame by frame with Camtasia's own exports. Expect small differences in
  how some effects look or move.
- **Apple silicon only.** There is no Intel build.
- Camtasia-only features (quizzes, hotspots, Smart Player, TechSmith cloud sharing) are
  kept in your project files but not supported.

## Source code and licences

WizRec is free software under the
[GNU General Public License v3.0 or later](https://github.com/devswizard/wizrec/blob/v0.1.1/LICENSE).
Its source code for this release is the `v0.1.1` tag of
[devswizard/wizrec](https://github.com/devswizard/wizrec/tree/v0.1.1).
The bundled libraries (FFmpeg and its codecs, Sparkle) are listed with their licences in
[THIRD_PARTY_NOTICES.md](https://github.com/devswizard/wizrec/blob/v0.1.1/THIRD_PARTY_NOTICES.md)
and, with exact versions, in `WizRec.app/Contents/Resources/Licenses/MANIFEST.txt`; their
source code is available from each project at those versions and from the Homebrew
formulae that built them.

WizRec is an independent project, not affiliated with or endorsed by TechSmith. Camtasia
is a trademark of TechSmith Corporation, used only to describe file compatibility.
