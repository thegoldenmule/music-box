// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AdminGate",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AdminGate", targets: ["AdminGate"])
    ],
    targets: [
        .target(
            name: "AdminGate",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AdminGateTests",
            dependencies: ["AdminGate"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
