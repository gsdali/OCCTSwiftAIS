# OCCTSwiftAIS

[![License](https://img.shields.io/badge/license-LGPL--2.1-blue)](LICENSE)

High-level **Application Interactive Services** for the OCCTSwift / OCCTSwiftViewport stack — selection-from-topology, manipulator widgets, dimension annotations, and standard scene objects, all in pure Swift.

> Current: **v0.7.0**. The SPEC's stated v0.x feature surface is fully shipped; v1.0 waits on OCCT 8.0.0 and SPI submission. See [SPEC.md](SPEC.md) for the design brief and [docs/CHANGELOG.md](docs/CHANGELOG.md) for per-release notes.

## What's in the box

- **Selection-from-topology** — pick a body / face / edge / vertex; round-trip the GPU pick to a `TopoDS_Face` / `Edge` / `Vertex` handle on the source `Shape`. Body and face highlights composite via the renderer's per-triangle style buffer (no overlay-mesh flicker).
- **Manipulator widgets** — translate and rotate gizmos with `snapTranslate` / `snapRotateDeg`, on the renderer's overlay layer (always-on-top), with native widget pick filtering. SwiftUI integration via `.attachManipulator(_:)`.
- **Dimensions** — `LinearDimension`, `AngularDimension`, `RadialDimension`. Topology-aware anchors (vertex / edge midpoint / face bbox center / circular-edge center) feed into OCCTSwiftViewport's existing `MeasurementOverlay` for leader lines + billboarded label.
- **Standard scene objects** — `Trihedron`, `WorkPlane`, `Axis`, `PointCloudPresentation`.
- **Selection survival** — `InteractiveContext.remap(_:using:rebindingTo:)` translates a pre-mutation `Selection` to the post-mutation shape's indices via OCCTSwift's history records.

[**→ Getting started**](docs/getting-started.md) walks through wiring all of this into a SwiftUI app.

## Installation

```swift
.package(url: "https://github.com/gsdali/OCCTSwiftAIS.git", from: "0.7.2"),
```

`OCCTSwiftAIS` transitively pulls `OCCTSwiftTools`, `OCCTSwiftViewport`, and `OCCTSwift`.

## 30-second example

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
                    print("selected face area:", face.area())
                }
            }
    }
}
```

## Architecture

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

OCCTSwiftAIS adds **scene-management semantics** an OCCT-style API expects (selection-on-topology, manipulators, dimensions) as a thin Swift layer on top of OCCTSwiftViewport's native Metal renderer. It is **not** a port of OCCT's `TKV3d` / `TKService` / `TKOpenGl` toolkits — see [`OCCTSwift/docs/visualization-research.md`](https://github.com/gsdali/OCCTSwift/blob/main/docs/visualization-research.md) for why.

## Supported platforms

| Platform | Status |
|---|---|
| macOS 15+ arm64 | Supported |
| iOS 18+ device + simulator arm64 | Supported |
| visionOS 1+ device + simulator arm64 | Supported |
| tvOS 18+ device + simulator arm64 | Supported |

Same floor as OCCTSwiftViewport.

## Documentation

- [Getting started](docs/getting-started.md) — selection, manipulators, dimensions, standard objects in one walkthrough.
- [SPEC.md](SPEC.md) — design rationale and the v0.x → v1.0 trajectory.
- [docs/CHANGELOG.md](docs/CHANGELOG.md) — what shipped in each release.

Sibling repos: [OCCTSwift](https://github.com/gsdali/OCCTSwift) (B-Rep kernel), [OCCTSwiftViewport](https://github.com/gsdali/OCCTSwiftViewport) (Metal renderer), [OCCTSwiftTools](https://github.com/gsdali/OCCTSwiftTools) (Shape ↔ ViewportBody bridge).

## License

LGPL 2.1 (matching OCCT). See [LICENSE](LICENSE).
