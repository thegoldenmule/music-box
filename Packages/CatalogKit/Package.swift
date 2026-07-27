// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CatalogKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CatalogKit", targets: ["CatalogKit"])
    ],
    dependencies: [
        .package(path: "../PolicyEngine")
    ],
    targets: [
        .target(
            name: "CatalogKit",
            dependencies: ["PolicyEngine"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CatalogKitTests",
            dependencies: ["CatalogKit", "PolicyEngine"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
