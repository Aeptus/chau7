// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Chau7",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Chau7", targets: ["Chau7"]),
        .library(name: "Chau7Core", targets: ["Chau7Core"])
    ],
    dependencies: [
        .package(url: "https://github.com/schiste/Chau7-SwiftTerm.git", revision: "7a6f4acd84c152170336832db4b2fda87722f3ef")
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
                .product(name: "SwiftTerm", package: "chau7-swiftterm")
            ],
            path: "Sources/Chau7"
        ),
        // Test target
        .testTarget(
            name: "Chau7Tests",
            dependencies: ["Chau7Core"],
            path: "Tests/Chau7Tests"
        )
    ]
)
