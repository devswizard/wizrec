import Foundation
import RenderEngine
import WizRecAssets

/// Effects and transitions the app's library panel offers, and the defaults a drop applies.
/// Sourced from WizRec's own catalog (`WizRecAssets.AssetCatalog`); `isRendered` says whether
/// RenderEngine draws the item (others pass through, or fall back to a fade for transitions).
/// Drag them onto the timeline with the pasteboard types `TimelineView.effectType` /
/// `TimelineView.transitionType` (string = `name`).
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
        /// RenderEngine draws it (`Compositor.renderedEffects`); otherwise it passes through.
        public var isRendered: Bool = true
        public var id: String { name }
    }

    /// A transition as the library offers it.
    public struct TransitionPreset: Sendable, Equatable, Identifiable {
        /// Transition `name` written to the project, e.g. `Fade`.
        public var name: String
        public var displayName: String
        /// Library grouping: `fades`, `wipes`, `slides`, `shapes`, `3d`.
        public var category: String = "fades"
        /// Length of a dropped transition, seconds (shortened to fit short clips).
        public var defaultSeconds: Double = TimelineLibrary.defaultTransitionSeconds
        /// RenderEngine draws it natively; otherwise the preview shows a plain fade.
        public var isRendered: Bool = true
        public var id: String { name }
    }

    /// Catalog effects in display order.
    public static let effects: [EffectPreset] = {
        let rendered = Compositor.renderedEffects
        return AssetCatalog.effects.map { e in
            EffectPreset(name: e.name, displayName: e.displayName, category: e.category,
                         parameters: e.parameters.map { Parameter($0.key, $0.value) },
                         isRendered: rendered.contains(e.name))
        }
    }()

    /// Catalog transitions in display order.
    public static let transitions: [TransitionPreset] = {
        let rendered = Compositor.renderedTransitions
        return AssetCatalog.transitions.map { t in
            TransitionPreset(name: t.name, displayName: t.displayName, category: t.category.rawValue,
                             defaultSeconds: t.defaultDuration > 0 ? t.defaultDuration : defaultTransitionSeconds,
                             isRendered: rendered.contains(t.name))
        }
    }()

    /// Length of a dropped transition not in the catalog, seconds.
    public static let defaultTransitionSeconds = 1.0

    public static func effect(named name: String) -> EffectPreset? { effects.first { $0.name == name } }
    public static func transition(named name: String) -> TransitionPreset? { transitions.first { $0.name == name } }
}
