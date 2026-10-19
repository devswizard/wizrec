<p align="center"><img src="Design/AppIcon/AppIcon.svg" width="128" alt="WizRec icon"></p>

# WizRec — free, open-source screen recorder & editor for macOS

*By Devs Wizard. Opens your Camtasia projects.*

WizRec records your screen, camera and microphone, then lets you edit on a multi-track
timeline. It opens and saves Camtasia® `.cmproj` / `.tscproj` projects losslessly, so a
project started in Camtasia on another Mac or PC can be edited here and opened there again.

> This is an independent project. It is not affiliated with or endorsed by TechSmith.
> Camtasia is a trademark of TechSmith Corporation and is used here only to describe file
> compatibility. The code is a clean-room implementation: it ships no TechSmith code,
> binaries or assets. Its built-in backgrounds, transitions, callouts, cursors and click
> effects are original work; its fonts are SIL Open Font License families.

## Features

| Area | State |
|---|---|
| Open/save `.cmproj`/`.tscproj` (format 2.0–10.0, Mac and Windows) | ✅ lossless: unknown keys, key order and number text survive; Camtasia opens our saves |
| Media: `.trec`, MP4/MOV (H.264, HEVC, ProRes), audio, images, PDF | ✅ FFmpeg + VideoToolbox, frame-accurate seek |
| Preview: transform, crop, opacity, keyframes, groups, stitched clips, speed | ✅ Metal compositor |
| Effects: rounded corners, drop shadow, mask, colour adjustment, blend modes, media matte, motion blur | ✅ |
| Transitions: 18 built in (fade, wipes, slides, iris, cube, flip, …) | ✅ our own shaders |
| Animated backgrounds (9 built in) and shader backgrounds from your projects | ✅ |
| Callouts: shapes, bubbles, arrows, text, blur/pixelate/highlight/spotlight | ✅ |
| Cursor layer and cursor effects from recordings | ✅ |
| Editing: split, trim, ripple, move with snapping, groups, stitch, speed, markers, copy/paste, undo | ✅ |
| Recorder: screen/region/window, camera, mic, system audio, cursor and click log | ✅ (needs Screen Recording permission) |
| Audio mixing, loudness normalisation | ✅ engine |
| Captions: SRT/VTT, transcription | ✅ engine; editor UI ⏳ |
| Export: MP4/MOV/GIF/audio | ✅ engine; export sheet ⏳ |

Out of scope: quizzes, hotspots, Smart Player, TechSmith cloud sharing.

## Install

Releases are notarized DMGs (arm64, macOS 14 or later). Until the first public release,
build from source.

## Build from source

Requirements: macOS 14+, Xcode 16+ (Swift 6), Homebrew `ffmpeg` and `pkg-config`.

```sh
brew install ffmpeg pkg-config
swift build
swift test
scripts/make-app.sh                 # → build/WizRec.app (uses Homebrew's FFmpeg)
open build/WizRec.app
```

Command-line tools:

```sh
swift run tscproj info "<project.cmproj>"
swift run tscproj roundtrip "<project.tscproj>" -o /tmp/copy.tscproj
swift run wizrec-record --list      # recorder check (needs Screen Recording permission)
```

A self-contained release DMG (FFmpeg bundled, optional signing and notarization):
`scripts/release.sh` — see [docs/RELEASING.md](docs/RELEASING.md).

## Documentation

- [User guide](docs/user-guide/README.md) and [keyboard shortcuts](docs/user-guide/keyboard-shortcuts.md)
- [Contributing](CONTRIBUTING.md), including the clean-room rules
- [Project format notes](docs/FORMAT.md) and behavioural specs in [docs/specs](docs/specs)
- [Releasing](docs/RELEASING.md)
- [Third-party notices](THIRD_PARTY_NOTICES.md)

## Layout

```
Sources/TSCProjKit/      project model and lossless I/O, exact time
Sources/MediaEngine/     demux/decode (libav + VideoToolbox), frame cache, waveforms
Sources/RenderEngine/    scene evaluation and Metal compositor: effects, transitions, callouts, cursor
Sources/TimelineEngine/  edit commands and undo
Sources/TimelineUI/      timeline view
Sources/AudioEngine/     mixer, loudness, audio effects
Sources/Exporter/        movie, GIF and audio export
Sources/Captions/        SRT/VTT, transcription, caption commands
Sources/Recorder/        ScreenCaptureKit / AVCapture recorder, cursor log, HUD
Sources/WizRecAssets/    built-in library: backgrounds, transitions, presets, cursors, fonts
Sources/PlayerKit/       playback pipeline;  Sources/WizRecApp/  the app
Tests/                   Swift Testing suites
docs/                    format notes, specs, user guide, release notes
```

## License

GPL-3.0-or-later. See [LICENSE](LICENSE). You may use, study, modify and share this
software. If you distribute a modified version, its source must stay open under the same
licence. Bundled third-party components keep their own licences
([THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)).
