import Foundation
import TSCProjKit

/// Straight-alpha RGBA colour, components 0–1.
public struct CaptionColor: Sendable, Equatable {
    public var r: Double, g: Double, b: Double, a: Double
    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
}

/// The `dynamic-caption-*` keys of a dynamic-caption callout's `def` (`docs/specs/captions.md` §3).
/// Defaults are the values seen in every Camtasia dynamic-caption sample (CP1). Units: seconds for
/// durations/times, callout px for widths and radii, fractions of the font size for `wordRectangleExtraSize`.
/// The glyph outline (`text-stroke-*`), font and box are ordinary callout keys, not repeated here.
public struct DynamicCaptionStyle: Sendable, Equatable {
    /// `dynamic-caption-style`: layout style; `"block"` is the only one observed.
    public var style = "block"
    /// `…-block-transition-name`; `""` = no transition between blocks.
    public var blockTransitionName = ""
    public var blockTransitionDuration = 0.5
    public var blockTransitionReverse = false
    /// Start a new block at each sentence end.
    public var newParagraphForEachSentence = false
    public var pastWordOpacity = 1.0
    public var futureWordOpacity = 1.0
    /// Highlight the word being spoken.
    public var currentWordEnabled = true
    public var currentWordColor = CaptionColor(1, 1, 1, 1)
    public var currentWordStrokeColor = CaptionColor(1, 0, 0, 1)
    /// Extra outline width of the current word, px.
    public var currentWordStrokeExtraWidth = 18.0
    /// Extra scale of the current word (0 = none, 0.2 = 120 %).
    public var currentWordExtraScale = 0.0
    public var currentWordGlowRadius = 0.0
    /// Seconds to ease the highlight from one word to the next.
    public var wordEasingDuration = 0.0
    /// Box behind the current word; alpha 0 = off.
    public var wordRectangleColor = CaptionColor(0, 0.4, 0.98, 0)
    public var wordRectangleCornerRadius = 20.0
    /// Padding of the word box, fraction of the font size.
    public var wordRectangleExtraSize = 0.125
    /// Seconds for the word box to move to the next word.
    public var wordRectangleTransitionTime = 0.1
    /// Box behind the whole block; alpha 0 = off.
    public var backgroundFillColor = CaptionColor(0, 0, 0, 0)
    public var backgroundCornerRadius = 19.2

    public init() {}

    static let prefix = "dynamic-caption-"

    /// Reads the keys from a callout `def`; missing keys keep the defaults.
    public init(def: JSONObject) {
        func n(_ k: String) -> Double? { def[Self.prefix + k]?.double }
        func s(_ k: String) -> String? { def[Self.prefix + k]?.string }
        func c(_ k: String, _ d: CaptionColor) -> CaptionColor {
            CaptionColor(n("\(k)-red") ?? d.r, n("\(k)-green") ?? d.g, n("\(k)-blue") ?? d.b, n("\(k)-alpha") ?? d.a)
        }
        style = s("style") ?? style
        blockTransitionName = s("block-transition-name") ?? blockTransitionName
        blockTransitionDuration = n("block-transition-duration") ?? blockTransitionDuration
        blockTransitionReverse = (n("block-transition-reverse") ?? 0) != 0
        newParagraphForEachSentence = (n("new-paragraph-for-each-sentence") ?? 0) != 0
        pastWordOpacity = n("past-word-opacity") ?? pastWordOpacity
        futureWordOpacity = n("future-word-opacity") ?? futureWordOpacity
        currentWordEnabled = (n("current-word-enabled") ?? 1) != 0
        currentWordColor = c("current-word-color", currentWordColor)
        currentWordStrokeColor = c("current-word-stroke-color", currentWordStrokeColor)
        currentWordStrokeExtraWidth = n("current-word-stroke-extra-width") ?? currentWordStrokeExtraWidth
        currentWordExtraScale = n("current-word-extra-scale") ?? currentWordExtraScale
        currentWordGlowRadius = n("current-word-glow-radius") ?? currentWordGlowRadius
        wordEasingDuration = n("word-easing-duration") ?? wordEasingDuration
        wordRectangleColor = c("word-rectangle-color", wordRectangleColor)
        wordRectangleCornerRadius = n("word-rectangle-corner-radius") ?? wordRectangleCornerRadius
        wordRectangleExtraSize = n("word-rectangle-extra-size") ?? wordRectangleExtraSize
        wordRectangleTransitionTime = n("word-rectangle-transition-time") ?? wordRectangleTransitionTime
        backgroundFillColor = c("background-fill-color", backgroundFillColor)
        backgroundCornerRadius = n("background-corner-radius") ?? backgroundCornerRadius
    }

    /// Whether a callout `def` is a dynamic caption (`modifier == "dynamicCaption"`).
    public static func isDynamicCaption(_ def: JSONObject) -> Bool { def["modifier"]?.string == "dynamicCaption" }

    /// The numeric keys (without prefix) in the alphabetical order Camtasia writes them, with values.
    public var numericEntries: [(String, Double)] {
        func c(_ k: String, _ v: CaptionColor) -> [(String, Double)] {
            [("\(k)-alpha", v.a), ("\(k)-blue", v.b), ("\(k)-green", v.g), ("\(k)-red", v.r)]
        }
        return [("background-corner-radius", backgroundCornerRadius)]
            + c("background-fill-color", backgroundFillColor)
            + [("block-transition-duration", blockTransitionDuration),
               ("block-transition-reverse", blockTransitionReverse ? 1 : 0)]
            + c("current-word-color", currentWordColor)
            + [("current-word-enabled", currentWordEnabled ? 1 : 0),
               ("current-word-extra-scale", currentWordExtraScale),
               ("current-word-glow-radius", currentWordGlowRadius)]
            + c("current-word-stroke-color", currentWordStrokeColor)
            + [("current-word-stroke-extra-width", currentWordStrokeExtraWidth),
               ("future-word-opacity", futureWordOpacity),
               ("new-paragraph-for-each-sentence", newParagraphForEachSentence ? 1 : 0),
               ("past-word-opacity", pastWordOpacity),
               ("word-easing-duration", wordEasingDuration)]
            + c("word-rectangle-color", wordRectangleColor)
            + [("word-rectangle-corner-radius", wordRectangleCornerRadius),
               ("word-rectangle-extra-size", wordRectangleExtraSize),
               ("word-rectangle-transition-time", wordRectangleTransitionTime)]
    }

    /// The string keys (without prefix), in Camtasia's order.
    public var stringEntries: [(String, String)] {
        [("block-transition-name", blockTransitionName), ("style", style)]
    }
}
