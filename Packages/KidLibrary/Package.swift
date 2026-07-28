// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "KidLibrary",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "KidLibrary", targets: ["KidLibrary"])
    ],
    dependencies: [
        .package(path: "../PolicyEngine"),
        .package(path: "../CatalogKit"),
        .package(path: "../FamilyStore"),
    ],
    targets: [
        .target(
            name: "KidLibrary",
            dependencies: ["PolicyEngine", "CatalogKit", "FamilyStore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "KidLibraryTests",
            dependencies: ["KidLibrary", "PolicyEngine", "CatalogKit", "FamilyStore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
