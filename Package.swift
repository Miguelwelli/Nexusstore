// swift-tools-version:5.9
import PackageDescription

// The Nexus Store core is written in dependency-free Swift + Foundation so that it can be
// compiled and tested on Linux CI (see .github/workflows/ci.yml) *and* shipped unchanged
// inside the iOS app target. Everything that touches SwiftUI/UIKit lives in NexusStore/Features
// and is not part of this package.
let package = Package(
    name: "NexusStoreCore",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(name: "NexusStoreCore", targets: ["NexusStoreCore"])
    ],
    targets: [
        .target(
            name: "NexusStoreCore",
            path: "NexusStore/Core"
        ),
        .testTarget(
            name: "NexusStoreCoreTests",
            dependencies: ["NexusStoreCore"],
            path: "Tests/NexusStoreCoreTests"
        )
    ]
)
