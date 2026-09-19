// swift-tools-version: 6.0
import PackageDescription

// Builds the patch core on its own so `swift test` can typecheck and exercise it
// without opening Xcode. The source is symlinked from BallparkMatchups/API —
// there is one copy, and it is the one the app compiles.
let package = Package(
    name: "PatchCore",
    platforms: [.macOS(.v13), .iOS(.v17)],
    targets: [
        .target(
            name: "PatchCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PatchCoreTests",
            dependencies: ["PatchCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
