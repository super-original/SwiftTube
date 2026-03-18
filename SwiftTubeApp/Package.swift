// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SwiftTubeApp",
    platforms: [
        .macOS(.v26)
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
