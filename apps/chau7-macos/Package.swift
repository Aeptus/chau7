// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Chau7",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
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
            exclude: [
                "AI/README.md",
                "Analytics/README.md",
                "App/README.md",
                "Appearance/README.md",
                "Commands/README.md",
                "Debug/README.md",
                "Editor/README.md",
                "Events/README.md",
                "History/README.md",
                "Keyboard/README.md",
                "Localization/README.md",
                "Logging/README.md",
                "Migration/README.md",
                "Monitoring/README.md",
                "MCP/README.md",
                "Notifications/README.md",
                "Overlay/README.md",
                "Performance/README.md",
                "Profiles/README.md",
                "Proxy/README.md",
                "Remote/README.md",
                "Rendering/README.md",
                "RustBackend/README.md",
                "Scripting/README.md",
                "Settings/README.md",
                "Settings/Views/README.md",
                "Snippets/README.md",
                "SplitPanes/README.md",
                "StatusBar/README.md",
                "Terminal/README.md",
                "Terminal/Rendering/README.md",
                "Terminal/Session/README.md",
                "Terminal/Views/README.md",
                "Telemetry/README.md",
                "TokenOptimization/README.md",
                "Utilities/README.md",
                "DataExplorer/README.md",
                "Repository/README.md",
                "Runtime/README.md",
                "Views/README.md",
            ],
            resources: [
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
            dependencies: [
                "Chau7Core",
                "Chau7",
                .product(name: "Atomics", package: "swift-atomics")
            ],
            path: "Tests/Chau7Tests",
            exclude: [
                "AI/README.md",
                "Analytics/README.md",
                "Appearance/README.md",
                "Commands/README.md",
                "CrossCutting/README.md",
                "History/README.md",
                "Localization/README.md",
                "Migration/README.md",
                "Notifications/README.md",
                "Profiles/README.md",
                "Proxy/README.md",
                "Remote/README.md",
                "Scripting/README.md",
                "Snippets/README.md",
                "Terminal/README.md",
                "Utilities/README.md",
            ]
        )
    ]
)
