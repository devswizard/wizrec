// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "WizRec",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TSCProjKit", targets: ["TSCProjKit"]),
        .library(name: "MediaEngine", targets: ["MediaEngine"]),
        .library(name: "RenderEngine", targets: ["RenderEngine"]),
        .library(name: "TimelineEngine", targets: ["TimelineEngine"]),
        .library(name: "TimelineUI", targets: ["TimelineUI"]),
        .library(name: "Recorder", targets: ["Recorder"]),
        .library(name: "AudioEngine", targets: ["AudioEngine"]),
        .library(name: "Exporter", targets: ["Exporter"]),
        .library(name: "Captions", targets: ["Captions"]),
        .library(name: "WizRecAssets", targets: ["WizRecAssets"]),
        .executable(name: "tscproj", targets: ["tscproj"]),
        .executable(name: "WizRec", targets: ["WizRecApp"]),
        .executable(name: "wizrec-testgen", targets: ["wizrec-testgen"]),
        .executable(name: "wizrec-record", targets: ["wizrec-record"]),
    ],
    dependencies: [
        // Sparkle 2 (MIT): app updates, linked into WizRecApp only (DECISIONS 2026-10-20).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.6"),
    ],
    targets: [
        // FFmpeg (libavcodec/libavformat/libavutil/libswscale), dynamically linked.
        // Homebrew: `brew install ffmpeg`. Used for tscc2 (.trec screen video).
        .systemLibrary(
            name: "CFFmpeg",
            pkgConfig: "libavcodec libavformat libavutil libswscale",
            providers: [.brew(["ffmpeg"])]
        ),
        .target(name: "TSCProjKit"),
        .target(name: "MediaEngine", dependencies: ["TSCProjKit", "CFFmpeg"]),
        .target(name: "RenderEngine", dependencies: ["TSCProjKit", "MediaEngine", "CaptionLayout", "WizRecAssets"]),
        .target(name: "TimelineEngine", dependencies: ["TSCProjKit"]),
        // M2: timeline view (agent "timelineui").
        .target(name: "TimelineUI", dependencies: ["TSCProjKit", "TimelineEngine", "MediaEngine", "RenderEngine",
                                                   "WizRecAssets"]),
        // M7: screen/camera/mic capture + cursor log (agent "recorder").
        .target(name: "Recorder"),
        // recorder: manual capture check from Terminal (`swift run wizrec-record --list`).
        .executableTarget(name: "wizrec-record", dependencies: ["Recorder"]),
        // M8: mixing, gain/volume keyframes, loudness, audio effects (agent "audio").
        .target(name: "AudioEngine", dependencies: ["TSCProjKit", "MediaEngine", "RenderEngine"]),
        // M9: MP4/MOV/GIF/audio export (agent "export").
        .target(name: "Exporter", dependencies: ["TSCProjKit", "MediaEngine", "RenderEngine", "AudioEngine", "CFFmpeg"]),
        // M10: transcription + captions (agent "captions").
        .target(name: "Captions", dependencies: ["TSCProjKit", "MediaEngine", "TimelineEngine", "CaptionLayout"]),
        // M10: pure dynamic-caption layout/state + transcript decoding, shared with RenderEngine (agent "captions").
        .target(name: "CaptionLayout", dependencies: ["TSCProjKit"]),
        // M11: WizRec's own asset library (backgrounds, transitions, presets, cursors, OFL fonts) (agent "ship").
        .target(name: "WizRecAssets", resources: [.copy("Resources/Fonts")]),
        .executableTarget(name: "tscproj", dependencies: ["TSCProjKit"]),
        // qa: synthetic test media + golden test-project generator (library shared with the tests).
        .target(name: "TestGenKit", dependencies: ["TSCProjKit", "TimelineEngine"]),
        .executableTarget(
            name: "wizrec-testgen",
            dependencies: ["TestGenKit", "TSCProjKit", "TimelineEngine", "MediaEngine", "PlayerKit", "WizRecAssets"]
        ),
        // Player logic (clock, frame snapping, audio mix, playback pipeline), testable without UI.
        .target(name: "PlayerKit", dependencies: ["TSCProjKit", "MediaEngine", "RenderEngine", "TimelineEngine", "AudioEngine",
                                                  "WizRecAssets"]),
        .executableTarget(
            name: "WizRecApp",
            dependencies: ["PlayerKit", "TSCProjKit", "MediaEngine", "RenderEngine", "TimelineEngine",
                           "TimelineUI", "Recorder", "AudioEngine", "Exporter", "Captions", "WizRecAssets",
                           .product(name: "Sparkle", package: "Sparkle")]
        ),
        .testTarget(
            name: "TSCProjKitTests",
            dependencies: ["TSCProjKit"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "MediaEngineTests", dependencies: ["MediaEngine", "TSCProjKit", "WizRecTestSupport"]),
        .testTarget(
            name: "RenderEngineTests",
            dependencies: ["RenderEngine", "TSCProjKit", "MediaEngine", "WizRecAssets", "CaptionLayout", "WizRecTestSupport"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "TimelineEngineTests",
            dependencies: ["TimelineEngine", "TSCProjKit"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "PlayerKitTests",
            dependencies: ["PlayerKit", "RenderEngine", "MediaEngine", "TSCProjKit", "TimelineEngine", "TestGenKit",
                           "WizRecAssets"]
        ),
        .testTarget(
            name: "GoldenTests",
            dependencies: ["RenderEngine", "MediaEngine", "TSCProjKit", "TestGenKit", "TimelineEngine",
                           "AudioEngine", "Captions", "Exporter"]
        ),
        .testTarget(
            name: "TimelineUITests",
            dependencies: ["TimelineUI", "TimelineEngine", "TSCProjKit", "MediaEngine", "RenderEngine", "WizRecAssets",
                           "WizRecTestSupport"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "RecorderTests", dependencies: ["Recorder"]),
        .testTarget(name: "AudioEngineTests", dependencies: ["AudioEngine", "TSCProjKit", "MediaEngine", "TestGenKit", "WizRecTestSupport"]),
        .testTarget(name: "ExporterTests", dependencies: ["Exporter", "TSCProjKit", "RenderEngine", "AudioEngine", "MediaEngine", "TestGenKit",
                                                   "WizRecTestSupport"]),
        .testTarget(name: "CaptionsTests", dependencies: ["Captions", "CaptionLayout", "TSCProjKit", "TimelineEngine", "MediaEngine",
                                                  "WizRecTestSupport"]),
        // RenderEngine only to check that every built-in shader translates, compiles and draws.
        .testTarget(name: "WizRecAssetsTests", dependencies: ["WizRecAssets", "RenderEngine", "MediaEngine"]),
        // qa: decode/composite throughput; runs only with WIZREC_PERF=1.
        .testTarget(
            name: "PerfTests",
            dependencies: ["RenderEngine", "MediaEngine", "TSCProjKit", "TestGenKit", "WizRecTestSupport"]
        ),
        // qa: helpers for test targets only (LoadGate timing bounds); never a product dependency.
        .target(name: "WizRecTestSupport", path: "Tests/WizRecTestSupport"),
    ]
)
