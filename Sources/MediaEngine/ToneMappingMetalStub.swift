// Placeholder for the Metal HDR tone mapper until render's `ToneMappingMetal.swift` lands
// (S5-MED-2). render deletes this file in the same commit that adds the real one.

import CoreVideo

/// Metal compute HDR → SDR tone mapper (placeholder: never available, so `.gpu` falls back to CPU).
final class MetalToneMapper {
    /// Nil when Metal is unavailable; the placeholder always is.
    init?(_ cpu: ToneMapper) { return nil }

    /// Tone-maps a bi-planar YCbCr buffer into a BGRA buffer of the same size.
    func convert(_ src: CVPixelBuffer, into dst: CVPixelBuffer) throws {
        throw MediaError.notImplemented
    }
}
