// Finite-memory signal processors. Each output sample is a pure function of the input over
// `[i − history, i + lookahead]` (and of the absolute sample index, for frame grids), so a block
// processed with that much context equals the same samples of one long pass: renders are
// deterministic and chunk-seamless by construction.

import Accelerate
import Foundation

/// An audio effect on a clip's media axis (e.g. noise removal, leveling).
protocol AudioProcessor: Sendable {
    /// Input samples needed before each output sample.
    var history: Int { get }
    /// Input samples needed after each output sample.
    var lookahead: Int { get }
    /// `input` covers absolute samples `[outputStart − history, outputStart + count + lookahead)`;
    /// returns `count` samples starting at `outputStart`.
    func process(_ input: Signal, outputStart: Int64, count: Int) -> Signal
}
