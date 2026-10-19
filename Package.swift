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
        .executable(name: "tscproj", targets: ["tscproj"]),
        .executable(name: "WizRec", targets: ["WizRecApp"]),
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
        .target(name: "RenderEngine", dependencies: ["TSCProjKit", "MediaEngine"]),
        .target(name: "TimelineEngine", dependencies: ["TSCProjKit"]),
        .executableTarget(name: "tscproj", dependencies: ["TSCProjKit"]),
        // Player logic (clock, frame snapping, audio mix, playback pipeline), testable without UI.
        .target(name: "PlayerKit", dependencies: ["TSCProjKit", "MediaEngine", "RenderEngine"]),
        .executableTarget(
            name: "WizRecApp",
            dependencies: ["PlayerKit", "TSCProjKit", "MediaEngine", "RenderEngine", "TimelineEngine"]
        ),
        .testTarget(
            name: "TSCProjKitTests",
            dependencies: ["TSCProjKit"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "MediaEngineTests", dependencies: ["MediaEngine"]),
        .testTarget(
            name: "RenderEngineTests",
            dependencies: ["RenderEngine", "TSCProjKit", "MediaEngine"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "TimelineEngineTests", dependencies: ["TimelineEngine", "TSCProjKit"]),
        .testTarget(
            name: "PlayerKitTests",
            dependencies: ["PlayerKit", "RenderEngine", "MediaEngine", "TSCProjKit"]
        ),
        .testTarget(
            name: "GoldenTests",
            dependencies: ["RenderEngine", "MediaEngine", "TSCProjKit"]
        ),
    ]
)
