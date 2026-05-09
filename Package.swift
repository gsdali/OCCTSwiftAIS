// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "OCCTSwiftAIS",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .visionOS(.v1),
        .tvOS(.v18)
    ],
    products: [
        .library(
            name: "OCCTSwiftAIS",
            targets: ["OCCTSwiftAIS"]
        ),
    ],
    dependencies: [
        // Brings in OCCTSwift and OCCTSwiftViewport transitively. Tools 1.0.2
        // graduates onto the SemVer-stable Viewport 1.0.x line and pulls the
        // v1.0.3 history APIs from OCCTSwift. Re-exports OCCTSwiftIO so
        // existing `OCCTSwiftTools.X` references still resolve. Body picking
        // metadata convention (vertices / vertexIndices / edgeIndices)
        // preserved across the v1.0 cut — see OCCTSwiftTools#10.
        .package(url: "https://github.com/gsdali/OCCTSwiftTools.git", from: "1.0.2"),
    ],
    targets: [
        .target(
            name: "OCCTSwiftAIS",
            dependencies: [
                .product(name: "OCCTSwiftTools", package: "OCCTSwiftTools"),
            ],
            path: "Sources/OCCTSwiftAIS",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "OCCTSwiftAISTests",
            dependencies: ["OCCTSwiftAIS"],
            path: "Tests/OCCTSwiftAISTests",
            resources: [
                .copy("Fixtures")
            ]
        ),
    ]
)
