# OCCTSwiftAIS

[![License](https://img.shields.io/badge/license-LGPL--2.1-blue)](LICENSE)

High-level Application Interactive Services for the OCCTSwift / OCCTSwiftViewport stack — selection-from-topology, manipulator widgets, dimension annotations, standard scene objects.

> Current: **v0.5.0** — body + face + edge + vertex selection-from-topology; translate + rotate manipulator widgets with `.attachManipulator(_:)` SwiftUI integration; linear / angular / radial dimensions; standard scene objects (Trihedron / WorkPlane / Axis / PointCloud). See [SPEC.md](SPEC.md) for the full v0.x → v1.0 trajectory and [docs/CHANGELOG.md](docs/CHANGELOG.md) for what's in each release.

## Usage

```swift
import SwiftUI
import OCCTSwift
import OCCTSwiftViewport
import OCCTSwiftAIS

@MainActor
struct CADView: View {
    @StateObject private var ais = InteractiveContext(viewport: ViewportController())

    var body: some View {
        MetalViewportView(controller: ais.viewport, bodies: $ais.bodies)
            .onAppear {
                if let part = Shape.box(width: 10, height: 5, depth: 3) {
                    ais.display(part)
                }
                ais.selectionMode = [.face]
            }
            .onChange(of: ais.selection) { _, sel in
                for face in sel.faces {
                    print("Selected face area:", face.area())
                }
            }
    }
}
```

## Architecture position

```
Application
   ↑
OCCTSwiftAIS         ← this repo (selection / manipulator / dimensions)
   ↑
OCCTSwiftTools       ← bridge: Shape ↔ ViewportBody
   ↑      ↑
OCCTSwift  OCCTSwiftViewport
(B-Rep)    (Metal)
```

## Why not a TKMetal port?

Because porting OCCT's `TKV3d` / `TKService` / `TKOpenGl` toolkits to Metal is a multi-year project that mostly duplicates work [OCCTSwiftViewport](https://github.com/gsdali/OCCTSwiftViewport) already does cleanly in native Metal. OCCTSwiftAIS adds the high-value scene-management semantics that an OCCT-style API needs (selection-on-topology, manipulators, dimensions) as a thin Swift layer on top — keeping all visualization OFF in OCCTSwift's xcframework.

Full reasoning: [`OCCTSwift/docs/visualization-research.md`](https://github.com/gsdali/OCCTSwift/blob/main/docs/visualization-research.md).

## Installation

```swift
.package(url: "https://github.com/gsdali/OCCTSwiftAIS.git", from: "0.1.0"),
```

## Supported platforms

| Platform | Status |
|---|---|
| macOS 15+ arm64 | Supported |
| iOS 18+ device + simulator arm64 | Supported |
| visionOS 1+ device + simulator arm64 | Supported |
| tvOS 18+ device + simulator arm64 | Supported |

Same floor as OCCTSwiftViewport.

## License

LGPL 2.1 (matching OCCT). See [LICENSE](LICENSE).
