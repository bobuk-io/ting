// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Ting",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        // Automatic updates from the public GitHub release feed.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        // Pure logic: config, key names, leader state machine, binding tree. No AppKit.
        .target(
            name: "TingCore",
            path: "Sources/TingCore",
            swiftSettings: [.swiftLanguageMode(.v5)]),
        // The menu-bar app (AppKit + SwiftUI + Carbon).
        .executableTarget(
            name: "Ting",
            dependencies: ["TingCore", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Ting",
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "TingServiceTests",
            dependencies: ["Ting", "TingCore"],
            path: "Tests/TingServiceTests",
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "TingCoreTests",
            dependencies: ["TingCore"],
            path: "Tests/TingCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
