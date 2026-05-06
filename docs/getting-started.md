# Getting started with OCCTSwiftAIS

A walkthrough that builds up a SwiftUI CAD viewer from a blank `MetalViewportView` to one with face selection, a translate gizmo, and a linear dimension. Everything in this guide compiles against `OCCTSwiftAIS` v0.7.2.

If you just want to see one snippet, the [README's 30-second example](../README.md#30-second-example) is enough. This guide is for "I want to understand each moving piece".

## 1. Add the package

```swift
// Package.swift
.package(url: "https://github.com/gsdali/OCCTSwiftAIS.git", from: "0.7.2"),
```

Then `.product(name: "OCCTSwiftAIS", package: "OCCTSwiftAIS")` on your target. AIS pulls `OCCTSwiftTools`, `OCCTSwiftViewport`, and `OCCTSwift` transitively — no need to declare them separately.

## 2. The two top-level objects

Every interactive scene has exactly two:

- **`ViewportController`** — owns camera, lighting, and the GPU pick pipeline. From `OCCTSwiftViewport`.
- **`InteractiveContext`** — owns the *scene state*: which `Shape`s are displayed, what's selected, what's hovered, which dimensions exist. Built on top of one `ViewportController`.

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
    }
}
```

`$ais.bodies` is the `Binding<[ViewportBody]>` `MetalViewportView` expects. `ais.viewport` is the controller you created.

## 3. Display a shape

`InteractiveContext.display(_:)` tessellates an OCCTSwift `Shape` and adds it to the scene. It returns an `InteractiveObject` — a UUID-keyed scene handle you can pass back to AIS later (to remove the body, attach a manipulator, or anchor a dimension).

```swift
.onAppear {
    if let box = Shape.box(width: 10, height: 5, depth: 3) {
        ais.display(box)
    }
}
```

`display(_:style:)` also takes an optional `PresentationStyle`:

```swift
let style = PresentationStyle(
    color: SIMD3<Float>(0.7, 0.6, 0.4),
    transparency: 0.0,
    displayMode: .shadedWithEdges,
    visible: true
)
ais.display(box, style: style)
```

Built-in presets: `.default`, `.ghosted`, `.highlighted`, `.hovered`.

## 4. Selection

Selection has two moving parts:

- **`selectionMode: Set<SelectionMode>`** — what *kinds* of pick produce a selection. Any combination of `.body`, `.face`, `.edge`, `.vertex`.
- **`selection: Selection`** — what's currently selected. Observable via SwiftUI's `onChange`.

```swift
.onAppear {
    if let part = Shape.box(width: 10, height: 5, depth: 3) {
        ais.display(part)
    }
    ais.selectionMode = [.face, .edge, .vertex]
}
.onChange(of: ais.selection) { _, sel in
    print("\(sel.count) sub-shapes selected")
    print("  faces: \(sel.faces.count)")
    print("  edges: \(sel.edges.count)")
    print("  vertices: \(sel.vertices.count)")
    for face in sel.faces {
        print("  face area: \(face.area())")
    }
}
```

The derived accessors:

| Accessor | Returns | Source |
| --- | --- | --- |
| `selection.faces` | `[Face]` | `shape.subShape(type: .face, index:)` → `Face(_:)` |
| `selection.edges` | `[Edge]` | `shape.subShape(type: .edge, index:)` → `Edge(_:)` |
| `selection.vertices` | `[SIMD3<Double>]` | `shape.vertex(at:)` |
| `selection.bodies` | `Set<InteractiveObject>` | distinct objects across all entries |

A click **replaces** the selection with the picked sub-shape. Empty-space clicks leave the selection alone. To accumulate, call `ais.select(_:)` / `ais.deselect(_:)` directly — those are additive (`Set` semantics, idempotent). `ais.clearSelection()` empties it.

Changing `selectionMode` also clears the current selection.

### Body-level vs face-level highlighting

- `.body` selections push the body's id to `viewport.selectedBodyIDs` — the renderer's built-in body highlight kicks in.
- `.face` selections write per-triangle style entries to the source body's `triangleStyles`, composited by the renderer's highlight pass. Color comes from `HighlightStyle.selectionColor`.

Tweak the highlight color:

```swift
ais.setHighlightStyle(HighlightStyle(
    selectionColor: SIMD3<Float>(1.0, 0.65, 0.0),  // orange
    hoverColor:     SIMD3<Float>(0.3, 0.8, 1.0),   // cyan (body-level only today)
    outlineWidth:   2.0
))
```

## 5. Manipulator widgets

A `ManipulatorWidget` is a translate or rotate gizmo bound to one `InteractiveObject`. You install it into an `InteractiveContext`; uninstall removes it cleanly and restores any pre-install transform on the target.

```swift
@StateObject private var ais  = InteractiveContext(viewport: ViewportController())
@State        private var widget: ManipulatorWidget? = nil

// On appear or wherever you decide a manipulator should appear:
let part = ais.display(Shape.box(width: 10, height: 5, depth: 3)!)
let w = ManipulatorWidget(target: part, mode: .translate)
w.size = 6                                      // arrow length in world units
w.snapTranslate = 0.25                          // snap to 0.25-unit increments
w.onChange = { transform in /* live during drag */ }
w.onCommit = { transform in /* on gesture release */ }
w.install(in: ais)
widget = w
```

The widget reports a `simd_float4x4` `transform`; during drag the *target body* gets `body.transform = preInstallTransform * widget.transform` so the user sees the part move in real time. On `onCommit` you typically transform the underlying `Shape` and re-display it.

For rotate, swap `mode: .rotate`, set `snapRotateDeg` instead of `snapTranslate`, and the gizmo renders three torus rings (X / Y / Z) at the target's centroid.

### SwiftUI integration

`.attachManipulator(_:)` wraps `MetalViewportView` with a `.highPriorityGesture(DragGesture)` that hit-tests the widget on touch-down:

```swift
var body: some View {
    Group {
        if let widget {
            MetalViewportView(controller: ais.viewport, bodies: $ais.bodies)
                .attachManipulator(widget)
        } else {
            MetalViewportView(controller: ais.viewport, bodies: $ais.bodies)
        }
    }
}
```

Drags on a handle drive the widget; drags off any handle forward to `controller.handleOrbit(translation:)` so the camera responds normally. Pinch / tap gestures still go to `MetalViewportView`'s own handlers.

If you want full manual control (e.g. a custom gesture stack), use the widget API directly:

```swift
let ndc: SIMD2<Float> = ...   // map your gesture point to [-1, 1] NDC, +Y up
let cam = ais.viewport.cameraState
let aspect = ais.viewport.lastAspectRatio

if !widget.isDragging,
   let axis = widget.hitTest(ndc: ndc, camera: cam, aspect: aspect) {
    widget.beginDrag(axis: axis, ndc: ndc, camera: cam, aspect: aspect)
}
widget.updateDrag(ndc: ndc, camera: cam, aspect: aspect)
// On gesture end:
widget.endDrag(commit: true)
```

## 6. Dimensions

A `Dimension` is a labeled measurement anchored on sub-shapes. Three concrete types:

- `LinearDimension(from:to:plane:?)` — distance between two anchors. Optional `WorkPlane` projects both anchors orthogonally before measuring.
- `AngularDimension(arms:apex:)` — angle at the apex.
- `RadialDimension(circularEdge:showDiameter:?)` — radius (or diameter) of a circular edge.

```swift
let part = ais.display(Shape.cylinder(radius: 4, height: 8)!)

// Linear distance between two corners.
let lin = LinearDimension(
    from: .vertex(part, vertexIndex: 0),
    to:   .vertex(part, vertexIndex: 7)
)
ais.add(lin)
print(lin.label)        // formatted distance, e.g. "9.85"
print(lin.distance)     // raw Float

// Find the first circular edge on the cylinder and dimension it.
for i in 0..<part.shape.edgeCount {
    if let edge = part.shape.edge(at: i), edge.isCircle {
        let rad = RadialDimension(
            circularEdge: .edge(part, edgeIndex: i),
            showDiameter: false
        )
        ais.add(rad)
        print(rad.label) // "R4.00"
        break
    }
}
```

Each dimension emits a `ViewportMeasurement` (distance / angle / radius) into `viewport.measurements`. The renderer's existing `MeasurementOverlay` SwiftUI Canvas draws leader lines + a billboarded label; AIS owns only the topology-aware anchor resolution.

To re-evaluate after the underlying anchors moved (e.g. you mutated the `Shape`):

```swift
ais.refreshDimensionMeasurement(lin)
```

`ais.remove(lin)` drops the dimension; `ais.removeAll()` clears every body, selection, and dimension in one go.

### Anchor resolution by sub-shape kind

| `SubShape` | Anchor world point |
| --- | --- |
| `.body(_)` | bbox center of `Shape.bounds` |
| `.face(_, idx)` | bbox center of `Face.bounds` |
| `.edge(_, idx)` | midpoint of `Edge.endpoints` |
| `.vertex(_, idx)` | `Shape.vertex(at: idx)` |

These are constant-time lookups. Curved-face area-weighted centroids and arc-length edge midpoints are future refinements.

## 7. Standard scene objects

Visual aids that ride on the `.userGeometry` pick layer but aren't selectable:

```swift
let trihedronBodies = Trihedron(at: .zero, axisLength: 5).makeBodies()
let workplaneBodies = WorkPlane(origin: .zero, normal: SIMD3<Float>(0, 0, 1), size: 50).makeBodies()
let axisBodies      = Axis(from: .zero, to: SIMD3<Float>(10, 0, 0)).makeBodies()
let cloudBodies     = PointCloudPresentation(
    points: [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 1, 1), SIMD3<Float>(2, 0, -1)]
).makeBodies()

ais.bodies.append(contentsOf: trihedronBodies)
ais.bodies.append(contentsOf: workplaneBodies)
ais.bodies.append(contentsOf: axisBodies)
ais.bodies.append(contentsOf: cloudBodies)
```

Each instance has an `ownsBody(id:)` predicate — handy for cleanup:

```swift
let tri = Trihedron(at: .zero, axisLength: 5)
ais.bodies.append(contentsOf: tri.makeBodies())
// later:
ais.bodies.removeAll { tri.ownsBody(id: $0.id) }
```

## 8. Selection survival across `Shape` mutation

`SubShape.face(_, faceIndex: 5)` only means "face 5" while the underlying `Shape` is unchanged. After a boolean op or a fillet, indices renumber.

`InteractiveContext.remap(_:using:rebindingTo:)` translates an old `Selection` to a new shape's indices using OCCTSwift's history records on a `TopologyGraph`:

```swift
let oldShape = Shape.box(width: 10, height: 10, depth: 10)!
let oldObj = ais.display(oldShape)
ais.select(.face(oldObj, faceIndex: 0))

// User mutates the shape — typically a fillet or boolean op.
// Build a TopologyGraph from the post-mutation shape with history recorded:
let newShape = ...
let graph = TopologyGraph(shape: newShape, parallel: false)!
graph.isHistoryEnabled = true
// (operations between old and new shape get recorded into `graph` here)

// Replace the displayed object with the new shape:
ais.remove(oldObj)
let newObj = ais.display(newShape)

// And carry the selection forward:
let oldSelection = ais.selection
ais.clearSelection()
let remapped = ais.remap(oldSelection, using: graph, rebindingTo: newObj)
for sub in remapped.subshapes {
    ais.select(sub)
}
```

`RemapStrategy` controls what happens for sub-shapes the history doesn't mention:

- `.dropMissing` (default) — drop them. Safest.
- `.keepUnchanged` — preserve the original index. Only safe if you know the operation didn't shift ordering (attribute-only edits, in-place transforms).

The 1-to-N case — e.g. an edge split by a fillet — automatically expands: a single `.edge(_, edgeIndex: 0)` in the old selection becomes two entries in the new one if the history records two replacements.

## 9. Testing tips

OCCT's `NCollection` has a known race condition on arm64 macOS that segfaults parallel test runs. Always:

```bash
OCCT_SERIAL=1 swift test --parallel --num-workers 1
```

To synthesize a `PickResult` in a test (e.g. to verify the end-to-end pick → `Selection` flow without an actual GPU readback):

```swift
import OCCTSwiftViewport
@testable import OCCTSwiftAIS

let raw = UInt32(bodyIndex & 0xFFFF)
        | (UInt32(primitiveIndex & 0x3FFF) << 16)
        | (UInt32(PrimitiveKind.face.rawValue) << 30)
let pick = PickResult(rawValue: raw, indexMap: [bodyIndex: bodyID])!
ctx.handlePick(pick)
```

The 14-bit / 16-bit / 2-bit packing matches the renderer's encoding.

## Where to next

- [SPEC.md](../SPEC.md) — the original design brief; useful when something here doesn't make sense and you want to see why.
- [docs/CHANGELOG.md](CHANGELOG.md) — what shipped per release.
- The test suites under `Tests/OCCTSwiftAISTests/` are the most exhaustive worked examples of the public API in real code.
