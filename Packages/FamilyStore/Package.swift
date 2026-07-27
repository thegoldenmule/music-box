// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "FamilyStore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "FamilyStore", targets: ["FamilyStore"])
    ],
    dependencies: [
        .package(path: "../PolicyEngine")
    ],
    targets: [
        .target(
            name: "FamilyStore",
            dependencies: ["PolicyEngine"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FamilyStoreTests",
            dependencies: ["FamilyStore", "PolicyEngine"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
