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
        // Brings in OCCTSwift and OCCTSwiftViewport transitively. Tools 0.6.0
        // splits file I/O into the new OCCTSwiftIO sibling and re-exports it,
        // so existing `OCCTSwiftTools.X` references still resolve. Tools 0.5.0+
        // populates `body.vertices` / `vertexIndices` / `edgeIndices` on the
        // source-shape convention, so AIS no longer has to override them — see
        // OCCTSwiftTools#10. Transitively resolves OCCTSwiftViewport ≥ 0.55.1
        // (renderer-backed `body.triangleStyles` highlight overlay).
        .package(url: "https://github.com/gsdali/OCCTSwiftTools.git", from: "0.6.0"),
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
