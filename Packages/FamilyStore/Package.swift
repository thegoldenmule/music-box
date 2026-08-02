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
            // A real store file written by an older build. It is the only way to
            // test a migration honestly: a fixture built from the *current*
            // `@Model` classes has the current shape whatever schema version it
            // is nominally written under, so it would pass by construction and
            // prove nothing. See MigrationTests.
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
