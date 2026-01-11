// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Chau7",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Chau7", targets: ["Chau7"])
    ],
    dependencies: [
        .package(url: "https://github.com/schiste/Chau7-SwiftTerm.git", from: "1.0.0")
    ],
    targets: [
        .executableTarget(
            name: "Chau7",
            dependencies: ["SwiftTerm"],
            path: "Sources/Chau7"
        )
    ]
)
