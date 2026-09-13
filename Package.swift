// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FootballWidget",
    platforms: [.macOS(.v26)],
    targets: [
        // Pure data + geometry. No UI, no networking, fully testable.
        .target(
            name: "FootballCore",
            path: "Sources/FootballCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The menu bar app itself.
        .executableTarget(
            name: "FootballWidget",
            dependencies: ["FootballCore"],
            path: "Sources/FootballWidget",
            exclude: ["Resources/Info.plist", "Resources/AppIcon.icns"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "FootballCoreTests",
            dependencies: ["FootballCore"],
            path: "Tests/FootballCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
