// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SwiftTubeApp",
    platforms: [
        .macOS("27.0")
    ],
    products: [
        .executable(name: "SwiftTubeApp", targets: ["SwiftTubeApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/mpvkit/MPVKit", from: "0.41.0")
    ],
    targets: [
        .executableTarget(
            name: "SwiftTubeApp",
            dependencies: [
                .product(name: "MPVKit", package: "MPVKit")
            ],
            path: "Sources/SwiftTubeApp",
            resources: [
                .copy("Resources")
            ],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "SwiftTubeAppTests",
            dependencies: ["SwiftTubeApp"]
        )
    ]
)
