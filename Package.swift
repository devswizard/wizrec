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
        .executable(name: "wizrec-testgen", targets: ["wizrec-testgen"]),
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
        // qa: synthetic test media + golden test-project generator (library shared with the tests).
        .target(name: "TestGenKit", dependencies: ["TSCProjKit"]),
        .executableTarget(name: "wizrec-testgen", dependencies: ["TestGenKit"]),
        .executableTarget(
            name: "WizRecApp",
            dependencies: ["TSCProjKit", "MediaEngine", "RenderEngine", "TimelineEngine"]
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
            name: "GoldenTests",
            dependencies: ["RenderEngine", "MediaEngine", "TSCProjKit", "TestGenKit"]
        ),
        // qa: decode/composite throughput; runs only with WIZREC_PERF=1.
        .testTarget(
            name: "PerfTests",
            dependencies: ["RenderEngine", "MediaEngine", "TSCProjKit", "TestGenKit"]
        ),
    ]
)
