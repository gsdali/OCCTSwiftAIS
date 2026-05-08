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
        // Brings in OCCTSwift and OCCTSwiftViewport transitively. Tools 1.0.0
        // graduates alongside OCCTSwift v1.0.0 (OCCT 8.0.0 GA, 2026-05-07).
        // Re-exports OCCTSwiftIO so existing `OCCTSwiftTools.X` references still
        // resolve. Body picking metadata convention (vertices / vertexIndices /
        // edgeIndices) preserved across the v1.0 cut — see OCCTSwiftTools#10.
        // Transitively resolves OCCTSwiftViewport ≥ 0.55.1 (renderer-backed
        // `body.triangleStyles` highlight overlay).
        .package(url: "https://github.com/gsdali/OCCTSwiftTools.git", from: "1.0.0"),
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
