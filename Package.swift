// swift-tools-version:5.7
//
// SwiftPM manifest for the extension's platform-independent core (container
// parsing, path handling, font de-obfuscation, request routing), so it can be
// unit-tested with `swift test` without Xcode or signing. The Xcode project
// compiles the same files directly into the Quick Look extension.

import PackageDescription

let package = Package(
    name: "EPUBCore",
    platforms: [.macOS(.v12)],
    products: [.library(name: "EPUBCore", targets: ["EPUBCore"])],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation", .upToNextMinor(from: "0.9.19")),
    ],
    targets: [
        .target(
            name: "EPUBCore",
            dependencies: ["ZIPFoundation"],
            path: "EPUBQuickLook/Core"
        ),
        .testTarget(
            name: "EPUBCoreTests",
            dependencies: ["EPUBCore", "ZIPFoundation"],
            path: "Tests/EPUBCoreTests"
        ),
    ]
)
