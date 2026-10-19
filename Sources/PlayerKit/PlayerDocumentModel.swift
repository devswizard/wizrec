import Foundation
import MediaEngine
import RenderEngine
import TSCProjKit

/// A source-bin entry whose file is not on this machine.
public struct MissingMedia: Sendable, Equatable, Identifiable {
    /// Source-bin id.
    public var id: Int64
    /// `src` as written in the project.
    public var src: String
    /// Where we looked for it.
    public var path: String
}

/// One opened project, read-only: bundle, render scene and media pool.
///
/// Reads through `ProjectBundle` only and never writes into the bundle.
@MainActor
public final class PlayerDocumentModel {
    public let bundle: ProjectBundle
    public let scene: SceneModel
    /// One pool per document.
    public let pool: MediaPool
    public let missing: [MissingMedia]

    public init(url: URL, cacheLimitBytes: Int = 768 << 20) throws {
        let bundle = try ProjectBundle(url: url)
        self.bundle = bundle
        scene = SceneModel(project: bundle.project, resolve: bundle.resolve)
        pool = MediaPool(cacheLimitBytes: cacheLimitBytes)
        missing = bundle.missingMedia().map {
            MissingMedia(id: $0.id, src: $0.src, path: bundle.resolve($0).path)
        }
    }

    /// Output sample rate for playback, Hz.
    public var audioSampleRate: Double {
        let r = bundle.project.audioSampleRate
        return r > 0 ? Double(r) : 44100
    }

    /// A playback engine for this document; `audio` false plays silently on the host clock.
    public func makeEngine(audio: Bool = true) -> PlaybackEngine {
        let player = audio ? AudioPlayback(scene: scene, pool: pool, sampleRate: audioSampleRate) : nil
        return PlaybackEngine(scene: scene, pool: pool, audio: player)
    }
}
