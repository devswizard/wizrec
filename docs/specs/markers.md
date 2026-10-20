# Spec: markers (timeline and clip markers)

Where Camtasia stores markers, also called the table of contents ("TOC"), in
`.tscproj`.

Tags: **[obs]** observed in files, **[inf]** inferred, **[?]** unknown.

## Evidence base

- **K1: BlendModePreview and MediaMattePreview.** Two bundle samples, read in
  place (formats 6.0 and 4.0, `editRate` 30). Both carry a timeline-level
  `toc` parameter. These are the only markers in the corpus. The demo, the
  vlog and the other 20 samples have none [obs].
- **K2: the demo's `docPrefs`** includes `DocPrefIsTocOpen` (0), the UI flag
  for the markers/TOC panel [obs]. The name ties "markers" to "toc".

## 1. Timeline markers

They are stored at `timeline.parameters.toc` [obs, K1]:

```json
"timeline": {
  …,
  "parameters": {
    "toc": {
      "type": "string",
      "keyframes": [
        { "endTime": 37, "time": 37, "value": "thumbnail frame", "duration": 0 }
      ]
    }
  },
  "captionAttributes": { … }
}
```

| Claim | Tag |
|---|---|
| The container is `timeline.parameters`: the same `parameters` object model as clips, at timeline level. Without markers, `timeline.parameters` is absent or `{}` | [obs] |
| `toc` is a string-typed animatable parameter (`type: "string"`, with no `defaultValue` and no `interp`) | [obs] |
| **One keyframe per marker.** `time` is the marker position; `endTime = time` and `duration = 0`; `value` is the marker's name | [obs] one marker in each of the 2 files |
| `time` is in **timeline ticks** of the project `editRate` (37 at `editRate` 30 = 1.233 s, inside both 4–5 s projects) | [obs value; inf axis] |
| Keyframes are sorted by `time`. Two markers at the same tick are [?] | [inf] |
| Display names are free text (UTF-8) | [inf] |

The samples' marker is called "thumbnail frame" and sits inside a preview
project. Camtasia evidently uses it to pick the frame for the effect tile
[inf]. MotionBlurPreview uses `metadata.EffectPreviewTime` (2.8, which looks
like seconds) for the same purpose [obs value; inf meaning].

### X8 results (runtime saves, 2026-10-20)

- *Modify ▸ Markers ▸ Add Timeline Marker* at 2 s, and the *Shift+M*
  shortcut with a clip selected at 4 s, both wrote **timeline** markers:
  `timeline.parameters.toc` with keyframes at 2 s and 4 s, each named
  **"Marker"** (the default name) [obs].
- `parameters` was inserted into `timeline` between `trackAttributes` and
  `captionAttributes`, as in K1 [obs].
- **Ripple delete does not move timeline markers.** With a marker at 8 s,
  ripple-deleting 2 s of media at 4–6 s shifted the clips left by 2 s, but
  the marker stayed at 8 s [obs]. WizRec's ripple commands must leave
  `toc` alone.

## 2. Clip (media) markers

**Camtasia 2026.2.3 (Mac) offers no way to create clip markers** [obs, X8]:

- The *Markers* menu holds only *Add Timeline Marker* and *Remove All*.
- The context menus of audio and video clips have no marker entry.
- *M*, *Ctrl+Shift+M* and *Option+M* on a selected clip wrote nothing.

No clip marker exists in the corpus either. The rest of this section is
the reading rule for older or Windows-authored projects.

Working assumption, consistent with §1 and with every other per-clip
parameter: a clip marker is a keyframe of `clip.parameters.toc`, with the
same shape, and its `time` is on the **clip's media-time axis**, like all
clip keyframes (`time-mapping.md` §6) [inf, unverified]. On a
`UnifiedMedia`, the parameter could sit on the parent or on the `video`
child [?].

**Experiment X8** (already scheduled by the lead) settles this:

1. Add one timeline marker at a known time and one clip marker on a clip
   that starts later than 0 s and has a left trim.
2. Save the project.
3. Diff the saved JSON.

## 3. Writer rules for WizRec

- To add a timeline marker, create `timeline.parameters.toc` if it is
  missing, as `{"type": "string", "keyframes": []}`. Then insert
  `{time, endTime: time, value: name, duration: 0}` in time order. Do not
  add `interp`.
- Key order inside `timeline`: in both samples `parameters` comes after
  `trackAttributes` and before `captionAttributes` [obs].
- Ripple edits do **not** move timeline markers (X8) [obs]. New markers are
  named "Marker" by default.
