// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ScoutKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "ScoutKit", targets: ["ScoutKit"]),
    ],
    dependencies: [
        // Anthropic Swift SDK — community (no official Swift SDK yet, we use URLSession)
    ],
    targets: [
        .target(
            name: "ScoutKit",
            dependencies: [],
            path: "Sources/ScoutKit"
        ),
        .testTarget(
            name: "ScoutKitTests",
            dependencies: ["ScoutKit"],
            path: "Tests/ScoutKitTests"
        ),
    ]
)
