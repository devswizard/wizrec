// Audio effects by `effectName` (AUD-3). Names come from one table; unknown effects pass through.

import Foundation

enum EffectRegistry {
    /// The processor for an effect, or nil to pass the signal through unchanged.
    static func processor(for e: AEffect, sampleRate: Double) -> (any AudioProcessor)? {
        nil
    }
}
