// swift-tools-version: 5.9
import PackageDescription

/// Keep strict-concurrency diagnostics enabled while the project migrates.
/// They remain warnings until the remaining isolation findings are triaged.
let strictConcurrencySettings: [SwiftSetting] = [
    .enableUpcomingFeature("StrictConcurrency")
]

/// Shared Swift logic for the Chau7 iOS remote app and its widget. The macOS
/// platform is declared so `swift build` and `swift test` run on a Mac host.
let package = Package(
    name: "Chau7Core",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "Chau7Core", targets: ["Chau7Core"])
    ],
    targets: [
        .target(
            name: "Chau7Core",
            path: "Sources/Chau7Core",
            exclude: ["README.md"],
            swiftSettings: strictConcurrencySettings
        ),
        .testTarget(
            name: "Chau7CoreTests",
            dependencies: ["Chau7Core"],
            path: "Tests/Chau7CoreTests",
            resources: [.process("Fixtures")],
            swiftSettings: strictConcurrencySettings
        )
    ]
)
