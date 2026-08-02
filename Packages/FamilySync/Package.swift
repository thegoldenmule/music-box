// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "FamilySync",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "FamilySync", targets: ["FamilySync"])
    ],
    dependencies: [
        .package(path: "../PolicyEngine"),
        .package(path: "../FamilyStore"),
    ],
    targets: [
        .target(
            name: "FamilySync",
            dependencies: ["PolicyEngine", "FamilyStore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FamilySyncTests",
            dependencies: ["FamilySync", "FamilyStore", "PolicyEngine"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
