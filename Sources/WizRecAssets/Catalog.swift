import Foundation

/// WizRec's own built-in library: backgrounds, transitions, effect presets, callout presets,
/// cursor art, click-effect art and fonts. Everything here is original Devs Wizard work
/// (GPL-3.0-or-later) or an upstream OFL font; nothing comes from TechSmith.
///
/// All lists are static, `Sendable` value types with no GPU or AppKit dependency, so UI code
/// and tests can read them freely. Names written into projects (`name` / `effectName` /
/// `shape`) are the identifiers of the project file format, so projects stay interoperable.
public enum AssetCatalog {
    /// Bumped whenever an item is added, removed or renamed.
    public static let version = 1

    /// Transitions for the library panel, in display order.
    public static var transitions: [TransitionAsset] { BuiltInTransitions.all }

    /// Animated shader backgrounds, in display order.
    public static var backgrounds: [BackgroundAsset] { BuiltInBackgrounds.all }

    /// Visual-effect presets (the effects RenderEngine draws), in display order.
    public static var effects: [EffectPreset] { BuiltInEffects.all }

    /// Callout presets (shapes, bubbles, arrows, text, region effects), in display order.
    public static var callouts: [CalloutPreset] { BuiltInCallouts.all }

    /// Cursor images (vector-drawn at any scale).
    public static var cursors: [CursorAsset] { BuiltInCursors.all }

    /// Click-effect animations.
    public static var clickEffects: [ClickEffectAsset] { BuiltInClickEffects.all }

    /// Bundled OFL fonts.
    public static var fonts: [FontAsset] { BuiltInFonts.all }

    /// The transition written to projects as `name`, e.g. `Fade`.
    public static func transition(named name: String) -> TransitionAsset? { transitions.first { $0.name == name } }

    /// The background whose `id` is `id`, e.g. `wizrec-aurora`.
    public static func background(id: String) -> BackgroundAsset? { backgrounds.first { $0.id == id } }

    /// The effect preset written to projects as `effectName`.
    public static func effect(named name: String) -> EffectPreset? { effects.first { $0.name == name } }

    /// The callout preset with `id`.
    public static func callout(id: String) -> CalloutPreset? { callouts.first { $0.id == id } }

    /// The cursor with `id`, e.g. `arrow`.
    public static func cursor(id: String) -> CursorAsset? { cursors.first { $0.id == id } }

    /// The click effect with `id`.
    public static func clickEffect(id: String) -> ClickEffectAsset? { clickEffects.first { $0.id == id } }
}

/// A built-in transition. Its look is our own GLSL shader, written against the host
/// convention of `docs/specs/transitions.md` §5: implicit `_Progress` (0 → 1),
/// `_TexCoord` (0…1, top-left origin, y down), `_ImageSize` (px), `_FragColor` (output,
/// straight alpha), and `textureA(uv)` / `textureB(uv)` returning the outgoing / incoming
/// frame (transparent outside 0…1).
public struct TransitionAsset: Sendable, Hashable, Identifiable {
    /// Library grouping.
    public enum Category: String, Sendable, CaseIterable {
        case fades, wipes, slides, shapes
        case threeD = "3d"
    }

    /// The transition `name` written to projects, e.g. `Fade`, `SlideLeft`.
    public var name: String
    public var displayName: String
    public var category: Category
    /// Default length of a dropped transition, seconds.
    public var defaultDuration: Double
    /// Fragment shader (GLSL, no `#version`); see the type doc for its inputs.
    public var glsl: String
    public var id: String { name }

    public init(name: String, displayName: String, category: Category, defaultDuration: Double = 1, glsl: String) {
        self.name = name; self.displayName = displayName; self.category = category
        self.defaultDuration = defaultDuration; self.glsl = glsl
    }
}

/// A visual-effect preset: what the library adds to a clip's `effects`.
public struct EffectPreset: Sendable, Hashable, Identifiable {
    /// `effectName` written to the project, e.g. `DropShadow`.
    public var name: String
    public var displayName: String
    /// `category` written to the project, e.g. `categoryVisualEffects`.
    public var category: String
    /// Parameter defaults, keyed as stored in the effect's `parameters`.
    public var parameters: [PresetValue]
    public var id: String { name }

    public init(name: String, displayName: String, category: String = "categoryVisualEffects",
                parameters: [PresetValue]) {
        self.name = name; self.displayName = displayName; self.category = category; self.parameters = parameters
    }
}
