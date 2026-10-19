import Foundation
import TSCProjKit

/// Generated media every case can use (all original, synthesised by `TestGen.makeMedia`).
public enum MediaID: String, Sendable, CaseIterable {
    /// 1920×1080 30 fps test card "A", 300 frames (10 s).
    case clipA = "A-testcard-1080p30.mp4"
    /// 1280×720 30 fps test card "B" (reversed palette), 300 frames.
    case clipB = "B-testcard-720p30.mp4"
    /// 1600×900 still test card with a checkerboard band.
    case card = "card-1600x900.png"
    /// 200×200 magenta marker square (for position tracking).
    case marker = "marker-200.png"
}

/// One effect-free golden test project.
public struct TestCase: Sendable {
    /// Directory and project name, e.g. `translate`.
    public let name: String
    /// One line: what the case exercises.
    public let summary: String
    public let uses: [MediaID]
    /// Timeline length, frames at 30 fps (the export must have exactly this many frames).
    public let durationFrames: Int
    /// Frames the golden test compares. Chosen at and around every edge in the case.
    public let frames: [Int]
    /// What a correct render shows at some frames (frame → description), for humans.
    public let expectations: [Int: String]
    /// What to check by eye when the project is opened in Camtasia.
    public let checklist: String
    /// For cases where test card A fills the canvas untransformed: timeline frame → source
    /// frame whose barcode the export must show. Checks the export against the time mapping.
    public var sourceFrames: [Int: Int] = [:]
    let build: @Sendable (ProjectBuilder, [MediaID: ProjectBuilder.Source]) -> Void
}

/// Frames → ticks at 30 fps / editRate 705600000.
@inline(__always) func f(_ n: Int64) -> Int64 { n * 23_520_000 }

private func c(_ v: Double) -> ParamSpec { .constant(v) }

private func kf(_ from: Int64, _ to: Int64, _ value: Double, _ interp: String) -> KeyframeSpec {
    KeyframeSpec(time: f(from), endTime: f(to), value: value, interp: interp)
}

extension TestGen {
    /// The M1 golden cases. All are effect-free; canvas 1920×1080, 30 fps, black background.
    /// Coordinates follow the project convention: px from canvas centre, +y up.
    public static let cases: [TestCase] = [
        TestCase(
            name: "baseline", summary: "Clip A full canvas, untransformed; timeline frame n shows source frame n.",
            uses: [.clipA], durationFrames: 150, frames: [0, 1, 29, 30, 75, 149],
            expectations: [0: "A 0000 fills the canvas", 149: "A 0149"],
            checklist: "Canvas shows test card A filling the frame; the counter reads A 0000 at the start.",
            sourceFrames: [0: 0, 1: 1, 29: 29, 30: 30, 75: 75, 149: 149],
            build: { b, m in
                b.tracks = [[b.video(m[.clipA]!, start: 0, duration: f(150))]]
            }),
        TestCase(
            name: "translate", summary: "Clip A at scale 0.5, moved +480 px right and +270 px up (top-right quadrant).",
            uses: [.clipA], durationFrames: 150, frames: [0, 75, 149],
            expectations: [0: "half-size card in the top-right quadrant, corners touching the canvas centre and top-right corner"],
            checklist: "Half-size card A sits exactly in the top-right quarter of the canvas.",
            build: { b, m in
                b.tracks = [[b.video(m[.clipA]!, start: 0, duration: f(150), params: [
                    "translation0": c(480), "translation1": c(270), "scale0": c(0.5), "scale1": c(0.5),
                ])]]
            }),
        TestCase(
            name: "scale-rotate", summary: "Clip A non-uniform scale 0.6×0.4, rotation2 = π/6 rad (30°).",
            uses: [.clipA], durationFrames: 150, frames: [0, 75, 149],
            expectations: [0: "squashed card rotated 30° (direction is what this case measures)"],
            checklist: "Card A is squashed (wider than tall) and rotated by 30°. Note whether it turns clockwise or counter-clockwise, and the rotation shown in the Properties panel.",
            build: { b, m in
                b.tracks = [[b.video(m[.clipA]!, start: 0, duration: f(150), params: [
                    "rotation2": c(Double.pi / 6), "scale0": c(0.6), "scale1": c(0.4),
                ])]]
            }),
        TestCase(
            name: "geometry-crop", summary: "Clip A at scale 0.8 with geometryCrop0..3 = 0.10, 0.20, 0.05, 0.15.",
            uses: [.clipA], durationFrames: 150, frames: [0, 75, 149],
            expectations: [0: "cropped card; four different crop amounts reveal the edge order"],
            checklist: "Card A is cropped by a different amount on each edge. Note which edge loses the most (expected: top 20 %, bottom 15 %, left 10 %, right 5 %).",
            build: { b, m in
                b.tracks = [[b.video(m[.clipA]!, start: 0, duration: f(150), params: [
                    "scale0": c(0.8), "scale1": c(0.8),
                    "geometryCrop0": c(0.10), "geometryCrop1": c(0.20), "geometryCrop2": c(0.05), "geometryCrop3": c(0.15),
                ])]]
            }),
        TestCase(
            name: "source-crop", summary: "Still image (1600×900) with sourceCrop0..3 = 0.10, 0.20, 0.05, 0.15.",
            uses: [.card], durationFrames: 90, frames: [0, 45, 89],
            expectations: [0: "image card cropped in source space"],
            checklist: "The still image is cropped by a different amount on each edge. Note which edge loses the most and whether the visible part stays centred or shifts.",
            build: { b, m in
                b.tracks = [[b.image(m[.card]!, start: 0, duration: f(90), params: [
                    "sourceCrop0": c(0.10), "sourceCrop1": c(0.20), "sourceCrop2": c(0.05), "sourceCrop3": c(0.15),
                ])]]
            }),
        TestCase(
            name: "opacity", summary: "Clip A full canvas; clip B (1280×720, native size) on top at opacity 0.5.",
            uses: [.clipA, .clipB], durationFrames: 150, frames: [0, 75, 149],
            expectations: [0: "B at 1280×720 in the centre, half transparent over A"],
            checklist: "Card B is in the middle at its native size and card A shows through it at half strength.",
            build: { b, m in
                b.tracks = [
                    [b.video(m[.clipA]!, start: 0, duration: f(150))],
                    [b.video(m[.clipB]!, start: 0, duration: f(150), params: ["opacity": c(0.5)])],
                ]
            }),
        keyframeCase(name: "keyframes-linear", interp: "linr"),
        keyframeCase(name: "keyframes-eioe", interp: "eioe"),
        TestCase(
            name: "keyframes-trimmed",
            summary: "Keyframe time base: clip A (scale 0.3) left-trimmed by 30 frames (mediaStart 30); x −600→+600 linear over media frames 60–120.",
            uses: [.clipA], durationFrames: 150, frames: [0, 29, 30, 45, 60, 75, 90, 105, 120, 149],
            expectations: [
                0: "A 0030 at x −600", 30: "A 0060, motion starts here if keyframes use media time",
                60: "A 0090 at x 0 (media time) — or just starting to move (timeline offset)",
                90: "A 0120 at x +600 (media time)",
            ],
            checklist: "The small card A starts at the counter A 0030 and slides from left to right. Note the timeline time (or the A counter) when it starts and stops moving.",
            build: { b, m in
                b.tracks = [[b.video(m[.clipA]!, start: 0, duration: f(150), mediaStart: f(30), params: [
                    "translation0": .animated(initial: -600, [kf(60, 120, 600, "linr")]),
                    "scale0": c(0.3), "scale1": c(0.3),
                ])]]
            }),
        TestCase(
            name: "keyframes-speed",
            summary: "Keyframes on a 2× clip (experiment X4): A at scalar 1/2, mediaStart 30, 120 frames; x −600→+600 linear over media frames 60–180.",
            uses: [.clipA], durationFrames: 120, frames: [0, 15, 30, 45, 60, 75, 90, 119],
            expectations: [
                0: "A 0030 at x −600",
                15: "A 0060: motion starts here if keyframes use media time (then ends at frame 75, A 0180)",
                30: "motion starts here instead if keyframes use mediaStart + timeline offset (ends past the clip end)",
            ],
            checklist: "Clip speed shows 2×. The small card A slides left to right. Note the A counter values when it starts and stops moving.",
            build: { b, m in
                b.tracks = [[b.video(m[.clipA]!, start: 0, duration: f(120), mediaStart: f(30), scalar: Rational(1, 2), params: [
                    "translation0": .animated(initial: -600, [kf(60, 180, 600, "linr")]),
                    "scale0": c(0.3), "scale1": c(0.3),
                ])]]
            }),
        TestCase(
            name: "group-offset",
            summary: "Group at timeline 1 s, inner offset (mediaStart) 2 s, scale 0.8, up 50 px; A (inner 0–4 s) left, B (inner 3–7 s) right.",
            uses: [.clipA, .clipB], durationFrames: 180, frames: [0, 29, 30, 59, 60, 89, 90, 179],
            expectations: [
                0: "black (group not started)", 30: "A 0060 on the left", 60: "A 0090 left + B 0000 right",
                89: "A 0119 left + B 0029 right", 90: "B 0030 right only", 179: "B 0119",
            ],
            checklist: "Nothing for the first second; then a group with card A on the left (counter starts at A 0060), card B joins on the right at 2 s (B 0000), A leaves at 3 s.",
            build: { b, m in
                let g = b.group(name: "Group 1", start: f(30), duration: f(150), mediaStart: f(60), params: [
                    "translation1": c(50), "scale0": c(0.8), "scale1": c(0.8),
                ]) {
                    [
                        [b.video(m[.clipA]!, start: 0, duration: f(120), params: [
                            "translation0": c(-480), "scale0": c(0.5), "scale1": c(0.5),
                        ])],
                        [b.video(m[.clipB]!, start: f(90), duration: f(120), params: [
                            "translation0": c(480), "scale0": c(0.75), "scale1": c(0.75),
                        ])],
                    ]
                }
                b.tracks = [[g]]
            }),
        TestCase(
            name: "stitched",
            summary: "StitchedMedia of A: cuts 0–60, 150–210, 90–120 (source frames), trimmed to start 15 frames in, 120 frames long.",
            uses: [.clipA], durationFrames: 120, frames: [0, 44, 45, 104, 105, 119],
            expectations: [0: "A 0015", 44: "A 0059", 45: "A 0150", 104: "A 0209", 105: "A 0090", 119: "A 0104"],
            checklist: "One clip on the timeline with two cut marks. The counter jumps A 0059 → A 0150 and A 0209 → A 0090.",
            sourceFrames: [0: 15, 44: 59, 45: 150, 104: 209, 105: 90, 119: 104],
            build: { b, m in
                b.tracks = [[b.stitched(m[.clipA]!, segments: [
                    (mediaStart: f(0), duration: f(60)), (mediaStart: f(150), duration: f(60)), (mediaStart: f(90), duration: f(30)),
                ], start: 0, duration: f(120), mediaStart: f(15))]]
            }),
        TestCase(
            name: "speed-2x", summary: "Clip A at 2× speed (scalar 1/2), starting at source frame 30, 120 frames long.",
            uses: [.clipA], durationFrames: 120, frames: [0, 1, 60, 119],
            expectations: [0: "A 0030", 1: "A 0032", 60: "A 0150", 119: "A 0268"],
            checklist: "Clip speed shows 2.00× (or 200 %); the counter advances by 2 per frame, from A 0030.",
            sourceFrames: [0: 30, 1: 32, 60: 150, 119: 268],
            build: { b, m in
                b.tracks = [[b.video(m[.clipA]!, start: 0, duration: f(120), mediaStart: f(30), scalar: Rational(1, 2))]]
            }),
        TestCase(
            name: "speed-half", summary: "Clip A at 0.5× speed (scalar 2), 180 frames long.",
            uses: [.clipA], durationFrames: 180, frames: [0, 1, 2, 3, 179],
            expectations: [0: "A 0000", 2: "A 0001", 179: "A 0089 (odd frames: hold or blend — this case measures which)"],
            checklist: "Clip speed shows 0.50× (or 50 %); the counter advances every second frame. Note if odd frames look blended (double image).",
            sourceFrames: [0: 0, 2: 1, 4: 2, 178: 89],
            build: { b, m in
                b.tracks = [[b.video(m[.clipA]!, start: 0, duration: f(180), scalar: Rational(2))]]
            }),
        TestCase(
            name: "two-track-overlap",
            summary: "Three tracks: A full canvas 0–5 s; still card (scale 0.5, left/up) 1–4 s; B (scale 0.5, from its frame 30) 2–5 s overlapping the card.",
            uses: [.clipA, .clipB, .card], durationFrames: 150, frames: [0, 29, 30, 59, 60, 119, 120, 149],
            expectations: [0: "A only", 30: "card over A", 60: "B over card over A (B 0030)", 120: "B over A, card gone"],
            checklist: "Layer order is A (bottom), image card, B (top): where B and the card overlap, B is in front.",
            build: { b, m in
                b.tracks = [
                    [b.video(m[.clipA]!, start: 0, duration: f(150))],
                    [b.image(m[.card]!, start: f(30), duration: f(90), params: [
                        "translation0": c(-400), "translation1": c(200), "scale0": c(0.5), "scale1": c(0.5),
                    ])],
                    [b.video(m[.clipB]!, start: f(60), duration: f(90), mediaStart: f(30), params: [
                        "translation0": c(-100), "translation1": c(50), "scale0": c(0.5), "scale1": c(0.5),
                    ])],
                ]
            }),
    ]

    /// Marker moves along y = −300: x −800 → 0 over frames 15–45 (1 s), holds, then 0 → +800 over
    /// frames 60–150 (3 s). Clip A (top track) scales 0.25 → 0.5 and fades 1 → 0.4 over frames 0–150.
    /// Two segment lengths with the same easing let the fit tell whether the curve depends on duration.
    private static func keyframeCase(name: String, interp: String) -> TestCase {
        TestCase(
            name: name,
            summary: "Keyframes (\(interp)): marker x −800→0 (frames 15–45) then 0→800 (60–150) at y −300; clip A scale 0.25→0.5, opacity 1→0.4 (0–150).",
            uses: [.clipA, .marker], durationFrames: 180,
            frames: [0, 15, 20, 30, 40, 45, 52, 60, 75, 105, 135, 150, 179],
            expectations: [0: "marker at x −800", 30: "marker halfway to 0 (exactly halfway only if linear)", 45: "marker at x 0",
                           150: "marker at x +800, A at half size and 40 % opacity"],
            checklist: "Open the marker clip's Properties: Position X animates from −800 to 0 and then to 800 (\(interp == "eioe" ? "eased" : "linear") arrows on the clip). Card A grows and fades.",
            build: { b, m in
                b.tracks = [
                    [b.image(m[.marker]!, start: 0, duration: f(180), params: [
                        "translation0": .animated(initial: -800, [kf(15, 45, 0, interp), kf(60, 150, 800, interp)]),
                        "translation1": c(-300),
                    ])],
                    [b.video(m[.clipA]!, start: 0, duration: f(180), params: [
                        "translation0": c(-480), "translation1": c(270),
                        "scale0": .animated(initial: 0.25, [kf(0, 150, 0.5, interp)]),
                        "scale1": .animated(initial: 0.25, [kf(0, 150, 0.5, interp)]),
                        "opacity": .animated(initial: 1, [kf(0, 150, 0.4, interp)]),
                    ])],
                ]
            })
    }
}
