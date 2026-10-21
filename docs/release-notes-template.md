<!--
  Release notes used by .github/workflows/release.yml for the draft GitHub Release.
  Written for v0.1.2 (v0.1.0's notes are in git history and on its GitHub Release).
  For a later release: rewrite "What's new", update "Known limits", and change the
  version in the download line and the tag in the links (v0.1.2) before tagging.
  See docs/RELEASING.md.
-->

A bug-fix and polish release of **WizRec**, the free, open-source screen recorder and
video editor for the Mac by Devs Wizard. It opens your Camtasia projects.

## Download

Download **WizRec-0.1.2.dmg** below. Nothing else to install: FFmpeg and everything
WizRec needs are inside the app.

**You need:** a Mac with Apple silicon (M1 or later) and macOS 14 Sonoma or later.

1. Open the DMG and drag **WizRec** into **Applications**. If you have an older WizRec,
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

**Getting started**
- **A start screen.** WizRec now opens on a start screen with your recent projects (with
  thumbnails) and buttons for **New Project**, **New Recording**, **Open Project…** and
  **Import Media…**. You can also drop a project or a video onto it. It comes back when you
  close the last project (**Window ▸ Start Screen**, ⇧⌘1), and you can turn it off at launch.
- **Opening projects works when Camtasia is installed.** The Open dialog used to grey out
  `.cmproj` and `.tscproj` files on Macs that also have Camtasia. They can now be chosen.
- **Open a video directly.** Opening a video, audio or image file starts a new project with
  that file already on the timeline.

**Editor**
- **A toolbar** with **Import**, **Record**, **Undo**, **Redo** and a clear **Export** button
  (also **File ▸ Export…**, ⌘E). Right-click the toolbar to customise it (zoom buttons are
  available there).

See the [0.1.1 release](https://github.com/devswizard/wizrec/releases/tag/v0.1.1) for the
previous changes (faster audio export, Camtasia-style Clip Speed and group drops, crash
fixes).

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
[GNU General Public License v3.0 or later](https://github.com/devswizard/wizrec/blob/v0.1.2/LICENSE).
Its source code for this release is the `v0.1.2` tag of
[devswizard/wizrec](https://github.com/devswizard/wizrec/tree/v0.1.2).
The bundled libraries (FFmpeg and its codecs, Sparkle) are listed with their licences in
[THIRD_PARTY_NOTICES.md](https://github.com/devswizard/wizrec/blob/v0.1.2/THIRD_PARTY_NOTICES.md)
and, with exact versions, in `WizRec.app/Contents/Resources/Licenses/MANIFEST.txt`; their
source code is available from each project at those versions and from the Homebrew
formulae that built them.

WizRec is an independent project, not affiliated with or endorsed by TechSmith. Camtasia
is a trademark of TechSmith Corporation, used only to describe file compatibility.
