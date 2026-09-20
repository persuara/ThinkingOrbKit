// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ThinkingOrbKit",
    // The real floor of `Canvas` + `TimelineView` (both introduced in the 2021 OS releases).
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "ThinkingOrbKit", targets: ["ThinkingOrbKit"])
    ],
    targets: [
        .target(name: "ThinkingOrbKit"),
        .testTarget(
            name: "ThinkingOrbKitTests",
            dependencies: ["ThinkingOrbKit"],
            resources: [
                // Reference output of the TypeScript engine (thinking-orbs, MIT).
                .copy("Resources/orbs-golden.json")
            ]
        ),
    ]
)
