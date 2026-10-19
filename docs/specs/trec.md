# Spec: `.trec` cursor, click and recording-metadata streams (`TSCM`)

Behavioural layout of the TechSmith metadata stored after `moov` in a
`.trec` recording, covering:

- cursor positions;
- cursor images and hotspots;
- mouse-button events;
- the capture region and display scale;
- how all of these map onto the screen video.

**Method.** File-level inspection only (CLAUDE.md rule 4.1): the user's own
recording and the three sample recordings inside the bundle, read in place
and parsed with our own scratch scripts. **No REA and no binary analysis
were needed.**

**Privacy.** Several `TSCM` records hold text from the user's desktop: app
names, window titles, device names and system details. This spec describes
their **framing only**. WizRec must never log, upload or vendor those
records' contents, nor copy a user's `.trec` into fixtures.

Tags: **[obs]** observed in files, **[inf]** inferred, **[?]** unknown.

## Evidence base

| Id | File | Recorder (`TSCR`) | Video |
|---|---|---|---|
| R1 | the user's demo recording (`recordings/…/Rec 10-19-2026.trec`) | Camtasia 2026.2.3, Mac | tscc2 3024×1964, 25.68 s, Retina |
| R2 | `EffectLogoResources/CursorEffectPreview.trec` (bundle) | Camtasia 2019, Mac | 384×205, 10.23 s |
| R3 | `EffectLogoResources/LeftClickEffectPreview.trec` (bundle) | Camtasia 2019, Mac | 384×205, 10.37 s |
| R4 | `EffectLogoResources/RightClickEffectPreview.trec` (bundle) | Camtasia Studio 9.0, **Windows** | 384×204, 6.6 s |
| R5 | the demo `ProjectThumbnail` (cursor drawn by Camtasia at 12.1 s) | | |

## 1. Atom framing

```
… moov │ free? │ TSCR (recorder id) │ TSCM
TSCM body = record*
record    = u32 BE  1                        (always 1 in 57 records)
            char[4] "DATA"
            u64 BE  recordLength             (includes these 16 header bytes)
            byte[16] streamGUID              (UUID, big-endian byte order)
            u32 LE  a                        (1, or 2 on the R1 cursor-image stream: format version [inf])
            u32 LE  elementSize              (bytes per element; 0 = variable-length payload)
            byte[]  payload                  (recordLength − 40 bytes)
```

[obs] The records tile `TSCM` exactly in all four files: R1 has 19, R2 13,
R3 13 and R4 12.

- **Multi-byte fields** are **big-endian** in the 16-byte header and
  **little-endian** everywhere after it [obs].
- **Fixed-size streams.** When `elementSize` > 0, the payload is
  `count = payloadLength / elementSize` elements with no count field and no
  padding [obs: the remainder is 0 everywhere].
- **Stream inventory in the project.** The project's
  `sourceBin[].sourceTracks[0].metaData` for a `.trec` video track lists the
  stream GUIDs present, each followed by `;` [obs: CursorEffectPreview
  project]. It is an inventory only, and needs no parsing for rendering.

### Stream catalog

All GUIDs share the suffix `-7a1f-11e2-83d0-0017f200be7f`. Only the first
group differs, so it is shown below. The first group of `2b7b6af2` means
`2b7b6af2-7a1f-11e2-83d0-0017f200be7f`.

| GUID prefix | elementSize | Content | Tag |
|---|---|---|---|
| `2b7b6af2` | 16 | **Cursor position samples** (§2) | [obs] |
| `2b7b6af1` | 0 | **Cursor images and cursor-change events** (§3) | [obs] |
| `2b7b6af0` | 12 | **Mouse-button events** (§4) | [obs] |
| `2b7b6af6` | 24 | **Capture region**: `(t, x, y, w, h)` (§5) | [obs] |
| `2b7b6afb` | 12 | **Display scale factor**: `(t, factor)` (§5) | [inf, strong] |
| `2b7b6af7` | 24 | Window-rectangle events `(t, x, y, w, h)`: the foreground or captured window's frame over time | [inf] R4: 3 events, one of them a maximised window at (−8, −8, 1936, 1056) |
| `2b7b6af3` | 16 | `(t, f64)`; the value is 1.0 at the recording start in all four | [?] |
| `2b7b6a08` | 12 | `(t, u32)` every ~5 s (R1 only) | [?] Periodic status; not cursor related |
| `2b7b6af5`, `2b7b6a01`, `2b7b6a05` | 16 | Empty in every file | [?] Candidates for keystrokes or other inputs |
| `2b7b6af8`, `2b7b6af9`, `2b7b6afa` | 0 | Empty in every file | [?] |
| `2b7b6afc`, `2b7b6a06`, `2b7b6a07`, `2b7b6a0a`, `2b7b6a0f`, `2b7b6a10`, `2b7b6a00`, `2b7b6aef` | 0 / 24 | **Private text metadata**: recording environment, devices, captured apps and windows | [obs: framing only, content not recorded here] |

**Timestamps (`t`)** are little-endian `f64` **seconds** on the recording
clock [obs]:

- R1's positions run from 0.0028 s to 25.678 s, and its video lasts
  25.678 s [obs];
- Windows recordings contain negative times (pre-roll, R4 from −5.04 s) and
  one absurd value (−103050.5 s on a button event) [obs].

**Rule:** treat `t` as **media time of the screen video in seconds** [inf,
strong]. Ignore events with `t < −60 s` or `t > duration + 60 s`, and clamp
the rest when sampling.

## 2. Cursor positions (`2b7b6af2`)

```
element (16 bytes) = f64 t, i32 x, i32 y
```

| Claim | Tag |
|---|---|
| Elements are sorted by `t` (non-decreasing) | [obs] all files |
| `x`, `y` are in the **same coordinate space as the capture region** (§5): global desktop coordinates, **origin top-left, +y down**, in points on Mac and pixels on Windows | [obs] R2: region x −993…−609, y 471…676; the first samples (−803, 571) fall inside, later ones leave the region. R1: matched against R5, below |
| Sampling: Mac writes about one sample per video frame **while the cursor moves**; an idle cursor writes nothing. R2 has a 3.2-s gap at rest. R1 has 756 samples in 25.7 s with a median step of 33.3 ms. Windows (R4) logs per OS event, at a median step of 4.5 ms | [obs] |
| Between samples the cursor **holds its last position** (step), unless a smoothing effect applies (`cursor-effects.md`) | [inf] R1 holds (930, 520) from 11.98 s to beyond 12.18 s, and the thumbnail matches that held point |
| Before the first sample, use the first sample | [inf] |

### Mapping to the video frame

```
u = (x − region.x) · videoWidth  / region.w      video px, +right
v = (y − region.y) · videoHeight / region.h      video px, +down
```

**Check against Camtasia's own render (R5)** [obs]:

1. At t = 12.1 s the held sample is (930, 520). The region is
   (0, 0, 1512, 982) and the video 3024×1964 (factor 2).
2. The layer is placed with scale 0.54989816700611 (`transform.md` §1), so
   the predicted hotspot in the 640×360 thumbnail is **(383.8, 190.6)**.
3. The cursor's arrow tip appears at about **(384–385, 192–193)**: within
   1.5 thumbnail px.
4. A +y-up reading would put it at y = 169, 22 px off.

## 3. Cursor images (`2b7b6af1`)

The payload is a sequence of variable-length **cursor events**. The first
event for each cursor id carries its image; later events reference the id
only [obs]. Records are little-endian.

```
event   = u32 L                    (bytes after this field)
          f64 t                    (seconds: when this cursor becomes the current one)
          u32 cursorId
          u32 reserved (0)
          payload (L − 16 bytes)
```

**Format a = 1** (R2, R3, R4, Camtasia 2019 and Windows 9.0) [obs]:

```
payload = u32 innerLength, then
          with image:   i32 hotX, i32 hotY, PNG bytes
          id only:      innerLength = 0
```

**Format a = 2** (R1, Camtasia 2026) [obs]:

```
payload = u32 innerLength, then
          with image:   u32 pngLength, i32 hotX, i32 hotY, PNG(pngLength), 24-byte trailer
          id only:      24-byte trailer (innerLength = 24)
trailer = i32 −1, u32 0, u32 0, u32 0, f32 1.0, f32 0.5        meaning [?]
```

| Claim | Tag |
|---|---|
| Images are RGBA PNGs at the **capture's backing scale**. R1 (Retina) has 56×80, 36×56 and 64×64; Mac 1× has 17×23; Windows has 32×32 | [obs] |
| **The hotspot `hotY` is measured from the image's bottom edge.** Top-down hotspot = `(hotX, imageHeight − hotY)` | [obs, strong] arrow images: (10, 70) in 56×80 → (10, 10), next to the arrow's first opaque pixel at (9, 7); 17×23 (4, 19) → (4, 4); Windows 32×32 (10, 21) → (10, 11), first opaque (10, 9). The I-beam 36×56 (18, 28) is centred either way |
| In format 2, the trailer's `f32 0.5` = 1 / backing scale is a candidate meaning, so 1 image px = 0.5 pt | [inf, weak] |
| Image switching: R1 starts with id 0 (arrow), then changes at 21.66 s (id 1), 21.77 s (back to 0), 21.87 s (id 2) and so on. R4 alternates ids 0 and 1 | [obs] |
| R2's first image PNG is cut short: its declared inner length runs 8 bytes past the record, and there is no `IEND` chunk. Decoders must tolerate a truncated final chunk | [obs] |
| The current cursor image at time t is the last event with `t_event ≤ t`. Before the first event, use the first image | [inf] |

The PNG content is the user's own cursor (or the OS cursor). When rendering
a user's project WizRec draws it from that user's file. It never ships
cursor art taken from these files or from Camtasia's `Cursors/` folder.

## 4. Mouse-button events (`2b7b6af0`)

```
element (12 bytes) = f64 t, u32 code
```

| `code` | Meaning | Evidence |
|---|---|---|
| 1 | Left button down | R1, R2, R3, R4: always followed about 0.1 s later by a 2 |
| 2 | Left button up | as above |
| 4 | Right button down | R4 (the right-click sample), followed 0.31 s later by 8 |
| 8 | Right button up | R4 |
| 256 | Present once at t ≈ 0 (Mac) | [?] A start-of-recording state marker. It is not a click |

- Codes behave as **bit flags** [inf]. A middle button is probably 16/32
  [?].
- **The click position is the cursor position at the click's `t`**, held
  from the last sample [inf]. No coordinates are stored in the element
  [obs].
- R1 has three left clicks, at 22.41, 23.71 and 25.23 s, each lasting about
  0.10 s [obs].

## 5. Capture region and scale

- **Region** (`2b7b6af6`): `(f64 t, i32 x, i32 y, i32 w, i32 h)`, i.e. the
  recorded area in the same global coordinates as the cursor [obs]:
  - R1: (0, 0, 1512, 982), a whole Retina display in points;
  - R2: (−993, 471, 384, 205);
  - R4: (783, 286, 384, 204).
- **`w × h × scale` equals the video size** [obs]:
  - R1: 1512×982 × 2 = 3024×1964;
  - R2: 384×205 × 1;
  - R4: 384×204, Windows px.
- **Scale factor** (`2b7b6afb`): `(f64 t, u32 factor)`. R1 = 2 (Retina);
  R2 and R3 = 1 [obs]. Its meaning is inferred from the size match above
  [inf, strong].
- **Several region events** (a region that moves while recording) are
  [?]: every file has exactly one. Use the latest event at or before t
  [inf].

## 6. How a project uses it

- A `ScreenVMFile` clip plays the `.trec`'s tscc2 track. Camtasia draws the
  cursor as a **separate layer** from §2–§3, because the pixels in the video
  have no cursor [obs: R1 frames show no cursor, while R5 shows one with
  cursor effects applied].
- Clip-level cursor parameters (`cursorScale`, `cursorOpacity`,
  `cursorTrackLevel`, `smoothCursorAcrossEditDuration`) and cursor effects
  are covered in `cursor-effects.md`.
- Clip media time t (seconds) selects the samples. For a split or trimmed
  clip, use `mediaStart`-based media time (`time-mapping.md`) [inf].

## 7. Writer notes (for WizRec's own recorder, M7)

- These rules apply only if WizRec ever writes `.trec`-compatible files.
  That is optional (CLAUDE.md, M7). The minimal streams Camtasia would need
  are [?]; a guess is `2b7b6af2`, `2b7b6af1`, `2b7b6af0`, `2b7b6af6` and
  `2b7b6afb`.
- For WizRec's own `cursor.json`, record the same information:
  - per-sample `(t, x, y)` in capture-region pixels, top-left origin;
  - cursor images with top-down hotspots and their backing scale;
  - button down/up events with flags;
  - the capture region and its scale.

## 8. Open questions and experiments

- **TM1: keystrokes.**
  1. Record a 10-s screen recording in Camtasia while typing "abc" and
     pressing ⌘S once.
  2. Save the recording as `tm1-keys.trec`.

  Comparing it with R1 shows which empty stream (`2b7b6af5`, `2b7b6a01` or
  `2b7b6a05`) fills up.
- **TM2: middle and double clicks.** Same setup. Double-click once, then
  middle-click once (if a mouse is available). Save as `tm2-clicks.trec`.
- **TM3: moving region.** Record a window region and move the window while
  recording. Save as `tm3-window.trec`. This tests `2b7b6af7` and
  whether the region changes.
- The meanings of `2b7b6af3` (value 1.0), the format-2 trailer and code 256
  are still [?]. None of them blocks rendering.
