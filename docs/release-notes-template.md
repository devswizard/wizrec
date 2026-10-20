<!--
  Release notes used by .github/workflows/release.yml for the draft GitHub Release.
  Written for v0.1.0. For a later release: rewrite "What's new", update "Known limits",
  and change the tag in the links (v0.1.0) before tagging. See docs/RELEASING.md.
-->

The first release of **WizRec**, a free, open-source screen recorder and video editor for
the Mac by Devs Wizard. It opens your Camtasia projects.

## Download

Download **WizRec-0.1.0.dmg** below. Nothing else to install: FFmpeg and everything
WizRec needs are inside the app.

**You need:** a Mac with Apple silicon (M1 or later) and macOS 14 Sonoma or later.

1. Open the DMG and drag **WizRec** into **Applications**.
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

Everything: this is the first public build.

**Camtasia projects**
- Open, edit and save Camtasia `.cmproj` and `.tscproj` projects (format 2.0 to 10.0,
  made on a Mac or a PC). Anything WizRec doesn't understand is kept exactly as it was,
  and Camtasia opens the projects WizRec saves.
- Missing media can be relinked, so a project moved from another computer opens cleanly.
- Every save keeps a backup of the previous version inside the project.

**Recording**
- Record the full screen, a region or a window, with camera, microphone and system
  audio. Countdown, pause and resume, and a recording timer with hotkeys.
- The mouse cursor and clicks are recorded separately from the picture, so cursor
  effects can be changed after recording. Keystroke capture is opt-in.
- Recordings go straight into the open project.

**Editing**
- Multi-track timeline with zoom, snapping, magnetic tracks, and track mute, hide
  and lock.
- Split, trim, ripple delete and ripple move, copy and paste, group and ungroup (including
  editing inside a group), stitch and unstitch, detach audio, clip speed, Extend Frame
  and markers. Everything can be undone.
- Media bin with drag-and-drop import; thumbnails and waveforms on the timeline.

**Look**
- Transform, crop, opacity and keyframe animation in a Metal preview that keeps up with
  4K, including HDR footage (HDR10 and HLG are shown correctly on SDR screens).
- Effects: rounded corners, drop shadow, border, reflection, mask, colour adjustment,
  all 31 blend modes, media matte and motion blur.
- 18 transitions (fades, wipes, slides, iris, cube, flip and more) and 9 animated
  backgrounds, all original to WizRec. Shader backgrounds in your own Camtasia projects
  play too.
- Callouts and annotations: shapes, speech bubbles, arrows, lines, text, highlighter,
  blur, pixelate, spotlight, sketch draw-on and keystroke callouts.
- Cursor effects from recordings: highlight, magnify, spotlight, click ripples and
  more.

**Audio**
- Track mixing with volume points, fades, mute and solo.
- Loudness normalisation, noise removal, volume levelling, emphasis and pitch, with the
  same effect names and defaults as Camtasia's audio panel.

**Captions**
- Transcribe speech to captions on your Mac: Apple's speech recognition out of the box,
  or whisper.cpp for offline, multilingual transcription (Bengali included). See
  [Captions](https://github.com/devswizard/wizrec/blob/v0.1.0/docs/user-guide/captions.md).
- Caption editor, dynamic (animated) caption styles, and SRT/VTT import and export.

**Export**
- MP4 (H.264 or HEVC), MOV (ProRes), animated GIF, and audio only (M4A, MP3, WAV).
- Resolution and frame-rate presets, batch export, progress and cancel. Exports are
  fast: a 26-second demo project exports to ProRes in about 3 seconds on Apple silicon.

## Known limits

- **Not notarized.** WizRec is signed ad hoc, not with an Apple Developer ID, so macOS
  asks before the first launch (see above).
- **No automatic updates yet.** The built-in updater is switched off in this release.
  Watch [Releases](https://github.com/devswizard/wizrec/releases) for new versions.
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
[GNU General Public License v3.0 or later](https://github.com/devswizard/wizrec/blob/v0.1.0/LICENSE).
Its source code for this release is the `v0.1.0` tag of
[devswizard/wizrec](https://github.com/devswizard/wizrec/tree/v0.1.0).
The bundled libraries (FFmpeg and its codecs, Sparkle) are listed with their licences in
[THIRD_PARTY_NOTICES.md](https://github.com/devswizard/wizrec/blob/v0.1.0/THIRD_PARTY_NOTICES.md)
and, with exact versions, in `WizRec.app/Contents/Resources/Licenses/MANIFEST.txt`; their
source code is available from each project at those versions and from the Homebrew
formulae that built them.

WizRec is an independent project, not affiliated with or endorsed by TechSmith. Camtasia
is a trademark of TechSmith Corporation, used only to describe file compatibility.
