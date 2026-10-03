// swift-tools-version: 5.9
import Foundation
import PackageDescription

/// Keep strict-concurrency diagnostics enabled while the project migrates.
/// They remain warnings until the remaining isolation findings are triaged.
let strictConcurrencySettings: [SwiftSetting] = [
    .enableUpcomingFeature("StrictConcurrency")
]

let package = Package(
    name: "Chau7",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .executable(name: "Chau7", targets: ["Chau7"]),
        .executable(name: "chau7-cli", targets: ["Chau7CLI"]),
        .executable(name: "magi", targets: ["MagiCLI"]),
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
            path: "Sources/Chau7Core",
            exclude: [
                "README.md"
            ],
            swiftSettings: strictConcurrencySettings
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
                "Views/README.md"
            ],
            resources: [
                .process("Resources/ar.lproj"),
                .process("Resources/en.lproj"),
                .process("Resources/es.lproj"),
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
            swiftSettings: strictConcurrencySettings,
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("IOSurface"),
                .linkedFramework("CoreVideo")
            ]
        ),
        // MAGI command-line interface
        .executableTarget(
            name: "MagiCLI",
            dependencies: [
                "Chau7Core"
            ],
            path: "Sources/MagiCLI",
            swiftSettings: strictConcurrencySettings
        ),
        // Chau7 command-line interface
        .executableTarget(
            name: "Chau7CLI",
            dependencies: [
                "Chau7Core"
            ],
            path: "Sources/Chau7CLI",
            swiftSettings: strictConcurrencySettings
        ),
        // Test target
        .testTarget(
            name: "Chau7Tests",
            dependencies: [
                "Chau7Core",
                "Chau7",
                "Chau7CLI",
                "MagiCLI",
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
                "Utilities/README.md"
            ],
            resources: [
                .process("Fixtures")
            ],
            swiftSettings: strictConcurrencySettings
        )
    ]
)

// A separate graph and scratch directory keep pure Core iteration independent
// of the app executable. --filter alone still builds the full test dependency graph.
if ProcessInfo.processInfo.environment["CHAU7_CORE_TESTS_ONLY"] == "1" {
    let testRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("Tests/Chau7Tests")
    let files = FileManager.default.enumerator(
        at: testRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
    )?.allObjects.compactMap { $0 as? URL } ?? []
    let importPattern = try NSRegularExpression(pattern: #"(?m)^\s*(?:@testable\s+)?import\s+(\w+)"#)
    var coreTests: [String] = []
    var excludedTests: [String] = []
    for file in files where file.pathExtension == "swift" {
        let text = try String(contentsOf: file, encoding: .utf8)
        let nsText = text as NSString
        let imports = Set(importPattern.matches(in: text, range: NSRange(location: 0, length: nsText.length))
            .map { nsText.substring(with: $0.range(at: 1)) })
        let relativePath = String(file.path.dropFirst(testRoot.path.count + 1))
        if imports.contains("Chau7Core"), imports.isDisjoint(with: ["Chau7", "Chau7CLI", "MagiCLI"]) {
            coreTests.append(relativePath)
        } else {
            excludedTests.append(relativePath)
        }
    }
    let readmes = files.filter { $0.lastPathComponent == "README.md" }
        .map { String($0.path.dropFirst(testRoot.path.count + 1)) }
    package.products = [.library(name: "Chau7Core", targets: ["Chau7Core"])]
    // Retain resolution declarations so SwiftPM never removes the shared lockfile.
    package.targets = [
        package.targets[0],
        .testTarget(
            name: "Chau7CoreTests", dependencies: ["Chau7Core"],
            path: "Tests/Chau7Tests", exclude: (excludedTests + readmes).sorted(),
            sources: coreTests.sorted(), resources: [.process("Fixtures")],
            swiftSettings: strictConcurrencySettings
        )
    ]
}
