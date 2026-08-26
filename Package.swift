// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SateCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "SateCore", targets: ["SateCore"])
    ],
    targets: [
        .target(
            name: "SateCore",
            path: "Sources/SateCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SateCoreTests",
            dependencies: ["SateCore"],
            path: "Tests/SateCoreTests",
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
