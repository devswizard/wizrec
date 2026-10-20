# Roster

SendMessage addresses of the live agents, written by the lead after each spawn.
Session 7 agents all finished; their branches are merged. None is live.

## Session 3 (2026-10-19)

| Name | Address | Branch |
|---|---|---|
| main (lead) | main | `main` |
| timeline | ab5ba6292cd6b02f8 | `agent/timeline4` |
| timelineui | a34700e5529cf33eb | `agent/timelineui4` |
| render | a765f68b21f3ce1e9 | `agent/render4` |
| export | a8717a7d82e69a81d | `agent/export4` |
| app | a3fe2bd1a7f4fc644 | `agent/app4` |
| captions | ac6e217c9b15c480d | `agent/captions4` |
| qa | acf56f36b7feeefb5 | `agent/qa4` |
| media | a89deb9fdb131344a | `agent/media4` |

Not spawned (inputs not delivered): researcher, audio, recorder, ship.

## Session 4 (2026-10-19)

| Name | Address | Branch |
|---|---|---|
| main (lead) | main | `main` |
| media | acf6a43ae29fd9196 | `agent/media5` |
| export | aaf661cbc15a24d27 | `agent/export5` |
| qa | a0472a8d717a91f63 | `agent/qa5` |
| ship | a163280e28495aa41 | `agent/ship5` |

Not spawned (inputs not delivered): researcher, render, timeline, audio,
captions, app.

## Session 5 (2026-10-20)

| Name | Address | Branch |
|---|---|---|
| main (lead) | main | `main` |
| researcher | a6879ff36181cea8d | `agent/researcher6` |
| qa | a3b5355b400e41f76 | `agent/qa6` |
| media | a9ac0a99beba87a9b | `agent/media6` |
| render | a5fac92c06082ebec | `agent/render6` |
| captions | af316ccda71a0a936 | `agent/captions6` |
| ship | a5ee05d5f4a6cf8fc | `agent/ship6` |
| app | a77d60dc311613a18 | `agent/app6` |
| timeline | a2e24b396c4b39da3 | `agent/timeline6` |

Spawn later (waiting on specs): audio.

### Session 5 restart (user stopped researcher, timeline, media, app; then asked to resume them)

Replacements continue from the stopped branches (+ uncommitted diffs applied
from the old worktrees, which are left untouched):

| Name | Address | Branch (from) |
|---|---|---|
| researcher | a76ca5a4bc30c9fb0 | `agent/researcher7` (researcher6) |
| audio | a7b7522bc45ba7baf | `agent/audio6` (new) |
| timeline | a19feda9afd2905e6 | `agent/timeline7` (timeline6) |
| media | ad73865fb2bc66524 | `agent/media7` (media6) |
| app | a6e42718f0c40802c | `agent/app7` (app6) |

Finished (idle, resumable): qa a3b5355b400e41f76, render a5fac92c06082ebec,
captions af316ccda71a0a936, ship a5ee05d5f4a6cf8fc.

## Session 7 (2026-10-20)

User: no licensed exports, no thumbnails as references, Sparkle off, manual
checks pending → no researcher/render/audio/captions.

| Name | Address | Branch |
|---|---|---|
| main (lead) | main | `main` (CI fixes) |
| ship | aa28312e4ab9a18e3 | `agent/ship9` |
| app | a9e409eb044fc2982 | `agent/app9` |
| qa | a6b149a71c4ac904b | `agent/qa9` |

### Session 7 wave 2 (user: "use multi agents")

app9, qa9, ship9 finished and merged. ship (aa28312e4ab9a18e3) is resumed for
the v0.1.0 draft check after the tag.

| Name | Address | Branch |
|---|---|---|
| app | ad9d414370529ee54 | `agent/app10` |
| timeline | acc7cf05fe9fd9abb | `agent/timeline10` |
| render | a0235298e2717e696 | `agent/render10` |
| qa | ac89e5809b08b7d6a | `agent/qa10` |
| docs | a43fa0d7aabf8f054 | `agent/docs10` |
