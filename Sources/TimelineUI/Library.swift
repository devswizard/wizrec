import Foundation

/// Effects and transitions the app's library panel offers, and the defaults a drop applies.
/// Effect parameters and defaults follow `docs/specs/effects/*.md`; the names are those the
/// RenderEngine draws. Drag them onto the timeline with the pasteboard types
/// `TimelineView.effectType` / `TimelineView.transitionType` (string = `name`).
public enum TimelineLibrary {
    /// One effect parameter default (`key` as stored in the effect's `parameters`).
    public struct Parameter: Sendable, Equatable {
        public var key: String
        public var value: Double
        public init(_ key: String, _ value: Double) { self.key = key; self.value = value }
    }

    /// An effect as the library offers it.
    public struct EffectPreset: Sendable, Equatable, Identifiable {
        /// `effectName` written to the project, e.g. `DropShadow`.
        public var name: String
        public var displayName: String
        /// `category` written to the project, e.g. `categoryVisualEffects`.
        public var category: String
        public var parameters: [Parameter]
        public var id: String { name }
    }

    /// A transition as the library offers it.
    public struct TransitionPreset: Sendable, Equatable, Identifiable {
        /// Transition `name` written to the project, e.g. `Fade`.
        public var name: String
        public var displayName: String
        public var id: String { name }
    }

    public static let effects: [EffectPreset] = [
        EffectPreset(name: "RoundCorners", displayName: "Rounded Corners", category: "categoryVisualEffects",
                     parameters: [Parameter("radius", 32), Parameter("top-left", 1), Parameter("top-right", 1),
                                  Parameter("bottom-left", 1), Parameter("bottom-right", 1)]),
        EffectPreset(name: "DropShadow", displayName: "Drop Shadow", category: "categoryVisualEffects",
                     parameters: [Parameter("angle", 3 * Double.pi / 2), Parameter("offset", 15), Parameter("blur", 25),
                                  Parameter("opacity", 0.2), Parameter("color-red", 31.0 / 255),
                                  Parameter("color-green", 31.0 / 255), Parameter("color-blue", 31.0 / 255),
                                  Parameter("color-alpha", 1), Parameter("enabled", 1)]),
        EffectPreset(name: "Mask", displayName: "Mask", category: "categoryVisualEffects",
                     parameters: [Parameter("mask-shape", 0), Parameter("mask-width", 1080), Parameter("mask-height", 1080),
                                  Parameter("mask-positionX", 0), Parameter("mask-positionY", 0),
                                  Parameter("mask-rotation", 0), Parameter("mask-cornerRadius", 0),
                                  Parameter("mask-blend", 0), Parameter("mask-opacity", 0), Parameter("mask-invert", 0)]),
        EffectPreset(name: "ColorAdjustment", displayName: "Color Adjustment", category: "categoryVisualEffects",
                     parameters: [Parameter("brightness", 0), Parameter("contrast", 0), Parameter("saturation", 0),
                                  Parameter("channel", 0), Parameter("shadowRampStart", 0), Parameter("shadowRampEnd", 0),
                                  Parameter("highlightRampStart", 1), Parameter("highlightRampEnd", 1)]),
    ]

    public static let transitions: [TransitionPreset] = [
        TransitionPreset(name: "Fade", displayName: "Fade"),
        TransitionPreset(name: "Dissolve", displayName: "Dissolve"),
        TransitionPreset(name: "FadeThroughBlack", displayName: "Fade Through Black"),
    ]

    /// Length of a dropped transition, seconds (shortened to fit short clips).
    public static let defaultTransitionSeconds = 1.0

    public static func effect(named name: String) -> EffectPreset? { effects.first { $0.name == name } }
    public static func transition(named name: String) -> TransitionPreset? { transitions.first { $0.name == name } }
}
