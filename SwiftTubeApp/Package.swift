// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SwiftTubeApp",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "SwiftTubeApp", targets: ["SwiftTubeApp"])
    ],
    targets: [
        .executableTarget(
            name: "SwiftTubeApp",
            path: "Sources/SwiftTubeApp",
            resources: [
                .copy("Resources")
            ]
        )
    ]
)
