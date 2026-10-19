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
        .target(name: "RenderEngine", dependencies: ["TSCProjKit", "MediaEngine", "CaptionLayout"]),
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
        .target(name: "Exporter", dependencies: ["TSCProjKit", "MediaEngine", "RenderEngine", "AudioEngine"]),
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
            dependencies: ["TestGenKit", "TSCProjKit", "TimelineEngine", "MediaEngine", "PlayerKit"]
        ),
        // Player logic (clock, frame snapping, audio mix, playback pipeline), testable without UI.
        .target(name: "PlayerKit", dependencies: ["TSCProjKit", "MediaEngine", "RenderEngine", "TimelineEngine", "AudioEngine"]),
        .executableTarget(
            name: "WizRecApp",
            dependencies: ["PlayerKit", "TSCProjKit", "MediaEngine", "RenderEngine", "TimelineEngine",
                           "TimelineUI", "Recorder", "AudioEngine", "Exporter", "Captions"]
        ),
        .testTarget(
            name: "TSCProjKitTests",
            dependencies: ["TSCProjKit"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "MediaEngineTests", dependencies: ["MediaEngine", "TSCProjKit"]),
        .testTarget(
            name: "RenderEngineTests",
            dependencies: ["RenderEngine", "TSCProjKit", "MediaEngine"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "TimelineEngineTests",
            dependencies: ["TimelineEngine", "TSCProjKit"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "PlayerKitTests",
            dependencies: ["PlayerKit", "RenderEngine", "MediaEngine", "TSCProjKit", "TimelineEngine", "TestGenKit"]
        ),
        .testTarget(
            name: "GoldenTests",
            dependencies: ["RenderEngine", "MediaEngine", "TSCProjKit", "TestGenKit", "TimelineEngine"]
        ),
        .testTarget(
            name: "TimelineUITests",
            dependencies: ["TimelineUI", "TimelineEngine", "TSCProjKit", "MediaEngine", "RenderEngine", "WizRecAssets"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "RecorderTests", dependencies: ["Recorder"]),
        .testTarget(name: "AudioEngineTests", dependencies: ["AudioEngine", "TSCProjKit", "MediaEngine"]),
        .testTarget(name: "ExporterTests", dependencies: ["Exporter", "TSCProjKit", "RenderEngine", "AudioEngine", "MediaEngine"]),
        .testTarget(name: "CaptionsTests", dependencies: ["Captions", "CaptionLayout", "TSCProjKit", "TimelineEngine", "MediaEngine"]),
        // RenderEngine only to check that every built-in shader translates, compiles and draws.
        .testTarget(name: "WizRecAssetsTests", dependencies: ["WizRecAssets", "RenderEngine", "MediaEngine"]),
        // qa: decode/composite throughput; runs only with WIZREC_PERF=1.
        .testTarget(
            name: "PerfTests",
            dependencies: ["RenderEngine", "MediaEngine", "TSCProjKit", "TestGenKit"]
        ),
    ]
)
