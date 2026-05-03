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
        // Brings in OCCTSwift and OCCTSwiftViewport transitively. SPM resolves
        // the highest compatible Viewport — which on 0.3.0 ships pulls 0.55.0
        // (PrimitiveKind / edge / vertex pick layers, needed by AIS v0.3.0
        // edge/vertex selection).
        .package(url: "https://github.com/gsdali/OCCTSwiftTools.git", from: "0.4.0"),
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
            path: "Tests/OCCTSwiftAISTests"
        ),
    ]
)
