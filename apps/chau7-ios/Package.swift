// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Chau7RemoteApp",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .executable(name: "Chau7RemoteApp", targets: ["Chau7RemoteApp"])
    ],
    targets: [
        .executableTarget(
            name: "Chau7RemoteApp",
            path: "Sources/Chau7RemoteApp"
        )
    ]
)
