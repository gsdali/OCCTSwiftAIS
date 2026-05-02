# OCCTSwiftAIS

[![License](https://img.shields.io/badge/license-LGPL--2.1-blue)](LICENSE)

High-level Application Interactive Services for the OCCTSwift / OCCTSwiftViewport stack — selection-from-topology, manipulator widgets, dimension annotations, standard scene objects.

> Status: **scaffolding**. No implementation yet — see [SPEC.md](SPEC.md) for the brief that describes what to build, in what order, and why.

## What it does (target API)

```swift
import SwiftUI
import OCCTSwift
import OCCTSwiftViewport
import OCCTSwiftAIS

@MainActor
struct CADView: View {
    @StateObject var viewport = ViewportController()
    @StateObject var ais: InteractiveContext

    init() {
        let vc = ViewportController()
        _viewport = StateObject(wrappedValue: vc)
        _ais = StateObject(wrappedValue: InteractiveContext(viewport: vc))
    }

    var body: some View {
        MetalViewportView(controller: viewport)
            .onAppear {
                let part = Shape.box(width: 10, height: 5, depth: 3)!
                ais.display(part)
                ais.selectionMode = [.face, .edge]
            }
            .onChange(of: ais.selection) { _, sel in
                for face in sel.faces {
                    print("Selected face area:", face.area)
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
| macOS 15+ arm64 | Planned |
| iOS 18+ device + simulator arm64 | Planned |
| visionOS 1+ device + simulator arm64 | Planned |
| tvOS 18+ device + simulator arm64 | Planned |

Same floor as OCCTSwiftViewport.

## Status

This repo is in **bootstrap**. Read [SPEC.md](SPEC.md) for the implementation brief.

## License

LGPL 2.1 (matching OCCT). See [LICENSE](LICENSE).
