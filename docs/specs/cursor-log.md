# Spec: WizRec cursor log (`cursor.json`), version 1

Our own format, written by the `Recorder` module next to each screen recording
and read by the cursor layer (M6). It is **not** a Camtasia format and does not
describe `.trec` data. Swift model: `CursorLog`, `CursorImage` and
`CursorEvent` in `Sources/Recorder/CursorLog.swift`.

Tags: **[def]** defined by this spec (normative), **[obs]** observed on this
machine, **[inf]** inferred, **[?]** open.

## 1. Files of one recording

`RecordingOptions.outputDirectory` receives [def]:

| File | Content |
|---|---|
| `screen.mp4` | Screen video, H.264 or HEVC, variable frame rate, cursor **not** drawn unless `cursorInVideo` |
| `camera.mp4` | Camera video (H.264/HEVC), only with `cameraID` |
| `microphone.m4a` | AAC, mono or stereo, only with `microphoneID` |
| `system-audio.m4a` | AAC stereo 48 kHz, only with `captureSystemAudio` |
| `cursor.json` | This log, only with `logCursor` or `logKeystrokes` |
| `cursors/cursor-<id>.png` | One PNG per distinct cursor image |

All files share **one timeline**: t = 0 is the end of the countdown, every
paused span is cut out of every file and out of this log, and the files end at
the same stop time [def]. Every source is converted to the host clock
(`CMClockGetHostTimeClock`) before mapping, so files line up at t = 0 without
any offset [def]. ScreenCaptureKit sample times are host time [inf: SCStream
exposes no other clock]; camera/microphone times are converted from
`AVCaptureSession.synchronizationClock` [def].

## 2. Top-level object

```json
{
  "format": "wizrec-cursor-log",
  "version": 1,
  "coordinateSpace": "capturedPixels",
  "origin": "topLeft",
  "timeUnit": "seconds",
  "videoWidth": 3024, "videoHeight": 1964,
  "pixelsPerPoint": 2,
  "sampleRate": 30,
  "duration": 12.3456,
  "keystrokesLogged": false,
  "cursors": [ { "id": 0, "file": "cursors/cursor-0.png", "width": 34, "height": 46, "hotspotX": 8, "hotspotY": 8 } ],
  "events": [ { "t": 0, "type": "move", "x": 1510.5, "y": 980 }, { "t": 0, "type": "cursor", "id": 0 } ]
}
```

| Key | Type | Meaning [def] |
|---|---|---|
| `format` | string | Always `"wizrec-cursor-log"`. |
| `version` | int | `1`. A reader accepts a file whose `version` it knows; later versions only add keys or event types. |
| `coordinateSpace` | string | `"capturedPixels"`: pixels of `screen.mp4`. |
| `origin` | string | `"topLeft"`: x grows right, y grows down. |
| `timeUnit` | string | `"seconds"` of recording time. |
| `videoWidth`, `videoHeight` | int | Pixel size of `screen.mp4` (even numbers). |
| `pixelsPerPoint` | number | Captured pixels per screen point (2 on Retina at native scale, 1 otherwise). |
| `sampleRate` | int | Position sampling rate per second (= capture frame rate). |
| `duration` | number | Recording duration in seconds (= `RecordingResult.duration`). |
| `keystrokesLogged` | bool | True only when keystroke logging was enabled **and** its event tap was installed. |
| `cursors` | array | Distinct cursor images in first-seen order (§4). |
| `events` | array | All events sorted by `t`; events with equal `t` keep their logged order (§3). |

Writers emit keys sorted alphabetically, no whitespace [def]. Readers must
ignore unknown keys and unknown event `type`s [def].

Numbers: `t` is rounded to 0.1 ms, positions to 0.01 px [def].

## 3. Events

Every event has `t` (number, seconds) and `type` (string). Positions `x`, `y`
are captured pixels, top-left origin, of the **hot spot** [def]. A position may
lie outside `[0, videoWidth) × [0, videoHeight)` when the cursor is off the
captured area; consumers clip or hide it [def].

| `type` | Extra keys | Meaning [def] |
|---|---|---|
| `move` | `x`, `y` | Position sample. Sampled every `1/sampleRate` s; a sample equal to the previous position is omitted, so the position **holds** until the next `move`. |
| `down` | `button`, `x`, `y`, `clickCount` | Button pressed. `clickCount` 2 = second press of a double click (system click state). |
| `up` | `button`, `x`, `y` | Button released. |
| `scroll` | `dx`, `dy`, `x`, `y` | Scroll by a point delta. CoreGraphics sign: `dy > 0` = wheel/fingers moved away from the user (content scrolls up/back). |
| `cursor` | `id` | The cursor image became `cursors[id]` and stays until the next `cursor` event. |
| `key` | `keyCode`, `modifiers`, optional `characters`, optional `repeat` | Key pressed (only when `keystrokesLogged`). `keyCode` = macOS virtual key code; `modifiers` ⊆ `shift`, `control`, `option`, `command`, `function`, `capsLock` in that order; `characters` = text the key produced (omitted when empty); `repeat: true` for auto-repeat. |

`button` is `"left"`, `"right"`, `"middle"` or `"button<N>"` (CoreGraphics
button number N ≥ 3) [def].

**Segment starts.** At t = 0 and at every resume point the writer re-states the
current position (`move`) and cursor image (`cursor`), even if unchanged, so
each segment is self-contained [def]. Events during a pause are dropped. A
button held across a pause may therefore have its `down` and `up` in different
segments, or the `up` missing; consumers end a press at the next `up` or at a
segment start [def].

**Timing.** Events are stamped with the host clock when the recorder sees them
(sampling timer, event-tap callback), not with the event's own timestamp
[def]. Latency against the pixels is about one display refresh [inf]; the
renderer may smooth positions (M6 `CursorPhysics` / smoothing).

## 4. Cursor images

| Key | Meaning [def] |
|---|---|
| `id` | Index used by `cursor` events (0, 1, 2… in first-seen order). |
| `file` | Path relative to the folder of `cursor.json`, `cursors/cursor-<id>.png`. |
| `width`, `height` | PNG size in captured pixels: the system cursor rendered at `pixelsPerPoint`. Draw it 1:1 on the video. |
| `hotspotX`, `hotspotY` | Hot spot in captured pixels from the PNG's top-left. Draw the PNG at (`x − hotspotX`, `y − hotspotY`). |

PNGs are sRGB RGBA (premultiplied before encoding). Two images are the same
cursor when size, hot spot and pixels are identical; each distinct one is
written once [def]. The image is the system cursor (`NSCursor.currentSystem`)
sampled at `sampleRate` [def]; animated cursors (spinning wait cursor) appear as
a change of `id` per sampled frame [inf].

Not recorded in v1: cursor hidden by the system (typing, full-screen video) [?];
cursor size from the Accessibility "Pointer size" setting is included because
the rendered image already reflects it [inf].

## 5. Coordinates per target

The capture's global rectangle (global display points, top-left origin, as
`CGDisplayBounds` and `CGEvent.location`) maps linearly to the video [def]:
`x_px = (x_pt − rect.minX) × videoWidth / rect.width`, same for y.

| Target | `rect` [def] |
|---|---|
| `display(id)` | `CGDisplayBounds(id)` |
| `region(id, r)` | `r` clamped to the display, snapped to whole pixels, offset by the display origin |
| `window(id)` | The window frame. The recorder re-reads the frame about 6 times per second and follows window moves; window **resizes** keep the initial scale [?: SCK scales the resized window to fit the fixed video size]. |

## 6. Privacy

- **Mouse** position, clicks, scroll and cursor images are logged whenever
  `logCursor` is true (default). They need no permission beyond Screen
  Recording [inf: listen-only mouse event taps and `CGEvent(source:)` are not
  gated by Input Monitoring; to be confirmed in the manual check]. If the mouse
  tap cannot be created, positions and cursor images are still logged.
- **Keystrokes** are logged only when `RecordingOptions.logKeystrokes` is true.
  The app must obtain explicit consent each time the user turns it on (the HUD
  shows a confirmation) [def].
  - It needs Input Monitoring (or Accessibility) permission for the app; without
    it `start` throws `permissionDenied` and records nothing [def].
  - Nothing is logged while secure event input is on: password fields,
    `sudo`/password prompts in Terminal, and any app that enables secure input
    [def]. macOS also withholds those events from listen-only taps [inf].
  - Text typed elsewhere, including into non-secure fields, **is** stored in
    `characters`. The log stays in the recording folder; it is never uploaded
    and never written into a project file by the recorder [def].
- The screen video excludes the HUD and its overlays
  (`RecorderExclusions`) [def].

## 7. Version history

| Version | Change |
|---|---|
| 1 (2026-10-19) | Initial format. |
