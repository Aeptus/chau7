// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Chau7",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13),
        .iOS(.v17)
    ],
    products: [
        .executable(name: "Chau7", targets: ["Chau7"]),
        .library(name: "Chau7Core", targets: ["Chau7Core"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0")
    ],
    targets: [
        // Core library with testable logic
        .target(
            name: "Chau7Core",
            dependencies: [],
            path: "Sources/Chau7Core"
        ),
        // Main executable
        .executableTarget(
            name: "Chau7",
            dependencies: [
                "Chau7Core",
                .product(name: "Atomics", package: "swift-atomics")
            ],
            path: "Sources/Chau7",
            resources: [
                .copy("Resources/chau7-proxy"),
                .process("Resources/ar.lproj"),
                .process("Resources/en.lproj"),
                .process("Resources/fr.lproj"),
                .process("Resources/he.lproj"),
                .process("Resources/aider-logo.png"),
                .process("Resources/chatgpt-logo.png"),
                .process("Resources/claude-logo.png"),
                .process("Resources/codex-logo.png"),
                .process("Resources/copilot-logo.png"),
                .process("Resources/cursor-logo.png"),
                .process("Resources/gemini-logo.png")
            ],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("IOSurface"),
                .linkedFramework("CoreVideo")
            ]
        ),
        // Test target
        .testTarget(
            name: "Chau7Tests",
            dependencies: ["Chau7Core"],
            path: "Tests/Chau7Tests"
        )
    ]
)
