// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PolicyEngine",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PolicyEngine", targets: ["PolicyEngine"])
    ],
    targets: [
        .target(
            name: "PolicyEngine",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PolicyEngineTests",
            dependencies: ["PolicyEngine"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
