// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Tapeline",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TSCProjKit", targets: ["TSCProjKit"]),
        .executable(name: "tscproj", targets: ["tscproj"]),
    ],
    targets: [
        .target(name: "TSCProjKit"),
        .executableTarget(name: "tscproj", dependencies: ["TSCProjKit"]),
        .testTarget(
            name: "TSCProjKitTests",
            dependencies: ["TSCProjKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
