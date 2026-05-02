# OCCTSwiftAIS — implementation spec

This document is a brief for the next agent (Claude or human) picking up implementation. Read it end-to-end before writing code, and read [`docs/visualization-research.md`](https://github.com/gsdali/OCCTSwift/blob/main/docs/visualization-research.md) in the OCCTSwift repo first — it captures *why* this layer exists rather than a TKMetal port.

## What this repo is

The high-level "Application Interactive Services" layer for the OCCTSwift / OCCTSwiftViewport stack. Equivalent in role to OCCT's own [`AIS_InteractiveContext`](https://dev.opencascade.org/doc/refman/html/class_a_i_s___interactive_context.html), but built natively in Swift over the existing Metal renderer in [OCCTSwiftViewport](https://github.com/gsdali/OCCTSwiftViewport) — not by porting OCCT's `TKV3d` / `TKService` / `TKOpenGl` toolkits.

The headline value: **selection-from-topology** (GPU pick → `TopoDS_Face` / `TopoDS_Edge` / `TopoDS_Vertex`), **manipulator widgets** (translate / rotate gizmos), and **dimension annotations** (linear, angular, radial). These are the three things app developers using OCCTSwiftViewport currently have to build themselves; OCCTSwiftAIS lifts them into a reusable, well-tested package.

It is **not** a port of OCCT's visualization C++ toolkits. Visualization in OCCT (TKV3d / TKService / TKOpenGl) stays disabled in OCCTSwift's xcframework. The layer cake is:

```
Application
   ↑
OCCTSwiftAIS         ← THIS REPO
   ↑
OCCTSwiftTools       ← bridge: Shape ↔ ViewportBody
   ↑      ↑
OCCTSwift  OCCTSwiftViewport
(B-Rep)    (Metal)
```

## Architecture position

OCCTSwiftAIS depends on **OCCTSwiftTools** (which transitively pulls in OCCTSwift and OCCTSwiftViewport). All Metal rendering goes through OCCTSwiftViewport's existing `MetalViewportView` / `ViewportController` machinery — OCCTSwiftAIS adds no new shaders or render passes; it composes on top.

Where OCCTSwiftViewport already provides:
- Camera / picking / display modes / lighting / shadows / section planes / measurements / grid / axes
- GPU pick buffer (TBDR imageblock) returning per-triangle `bodyIndex` + `faceIndex`

OCCTSwiftAIS adds:
- The mapping from `(bodyIndex, faceIndex)` ↔ `(Shape, TopoDS_Face)` ↔ `Selection`
- Hover / highlight / ghost styling on top of pick results
- Manipulator widgets (translate / rotate gizmos with snap)
- Dimension annotations (linear / angular / radial; with leader lines, labels, billboarded text)
- Standard scene objects (`Trihedron`, `WorkPlane`, `Axis`, `PointCloudPresentation`)

## Public API target shape

The headline namespace is `InteractiveContext` — read it as "OCCTSwift's answer to `AIS_InteractiveContext` without inheriting OCCT's C++ idioms". Pseudo-Swift below; finalise during implementation:

```swift
import SwiftUI
import OCCTSwift
import OCCTSwiftViewport
import OCCTSwiftTools

/// Per-scene interactive state. One `InteractiveContext` ↔ one `ViewportController`.
@MainActor
public final class InteractiveContext: ObservableObject {
    public init(viewport: ViewportController)

    // MARK: - Display

    /// Display a shape with topology-aware selection enabled.
    @discardableResult
    public func display(_ shape: Shape,
                        style: PresentationStyle = .default) -> InteractiveObject

    public func remove(_ object: InteractiveObject)
    public func removeAll()

    // MARK: - Selection

    /// What kinds of sub-shape can be selected.
    public var selectionMode: Set<SelectionMode>  // .body | .face | .edge | .vertex

    /// Currently selected sub-shapes.
    public private(set) var selection: Selection
    public func select(_ subshape: SubShape)
    public func deselect(_ subshape: SubShape)
    public func clearSelection()

    /// Hover state. Updated by the viewport controller when the cursor moves.
    public private(set) var hover: SubShape?

    // MARK: - Highlighting / styling

    public func setStyle(_ style: PresentationStyle, for object: InteractiveObject)
    public func setHighlightStyle(_ style: HighlightStyle)
}

/// Erased reference to something in the scene.
public struct InteractiveObject: Hashable, Sendable {
    public let id: UUID
    public let shape: Shape
}

/// A specific TopoDS_Face / TopoDS_Edge / TopoDS_Vertex inside a displayed shape,
/// or the whole body. Survives shape mutation only as long as the topology indices
/// are stable.
public enum SubShape: Hashable, Sendable {
    case body(InteractiveObject)
    case face(InteractiveObject, faceIndex: Int)
    case edge(InteractiveObject, edgeIndex: Int)
    case vertex(InteractiveObject, vertexIndex: Int)
}

/// Snapshot of selected sub-shapes.
public struct Selection: Hashable, Sendable {
    public let subshapes: Set<SubShape>
    public var bodies: Set<InteractiveObject> { /* derived */ }
    public var faces: [TopoDS_FaceRef] { /* concrete TopoDS handles via OCCTSwift */ }
}

public enum SelectionMode: Hashable, Sendable { case body, face, edge, vertex }

/// Visual treatment.
public struct PresentationStyle: Sendable, Equatable {
    public var color: SIMD3<Float>
    public var transparency: Float
    public var displayMode: DisplayMode  // .shaded, .wireframe, .shadedWithEdges
    public var visible: Bool

    public static let `default`: PresentationStyle
    public static let ghosted: PresentationStyle    // semi-transparent, dimmed
    public static let highlighted: PresentationStyle
    public static let hovered: PresentationStyle
}

public struct HighlightStyle: Sendable, Equatable {
    public var selectionColor: SIMD3<Float>
    public var hoverColor: SIMD3<Float>
    public var outlineWidth: Float
}
```

### Manipulator widget

```swift
@MainActor
public final class ManipulatorWidget: ObservableObject {
    public enum Mode { case translate, rotate, scale }

    public init(target: InteractiveObject, mode: Mode = .translate)

    /// Bind to a viewport — the widget renders itself and consumes pointer events.
    public func install(in viewport: ViewportController)
    public func uninstall()

    /// Final transform once the user commits. Continuous transform during drag.
    public var transform: simd_float4x4
    public var onChange:  ((simd_float4x4) -> Void)?
    public var onCommit:  ((simd_float4x4) -> Void)?

    /// Snap configuration.
    public var snapTranslate: Float?  // grid spacing, nil = continuous
    public var snapRotateDeg: Float?  // angular step in degrees
}
```

### Dimensions

```swift
public protocol Dimension: AnyObject, Sendable {
    var label: String { get }
    var anchorPoints: [SIMD3<Float>] { get }
}

public final class LinearDimension: Dimension {
    public init(from: SubShape, to: SubShape, plane: WorkPlane?)
}

public final class AngularDimension: Dimension {
    public init(arms: (SubShape, SubShape), apex: SubShape)
}

public final class RadialDimension: Dimension {
    public init(circularEdge: SubShape)
}

extension InteractiveContext {
    @discardableResult
    public func add<D: Dimension>(_ dimension: D) -> D
    public func remove(_ dimension: any Dimension)
}
```

### Standard objects

```swift
public final class Trihedron {
    public init(at origin: SIMD3<Float>, axisLength: Float = 1.0)
}

public final class WorkPlane {
    public init(origin: SIMD3<Float>, normal: SIMD3<Float>, size: Float = 100)
}

public final class Axis {
    public init(from: SIMD3<Float>, to: SIMD3<Float>, color: SIMD3<Float>)
}

public final class PointCloudPresentation {
    public init(points: [SIMD3<Float>], colors: [SIMD3<Float>]? = nil)
}
```

## Implementation guidance

### Selection-from-topology — the load-bearing piece

OCCTSwiftViewport's `ViewportBody` already carries `faceIndices: [Int32]` (one per triangle, source-face index). When `OCCTSwiftTools.ViewportBody.from(_:Shape)` builds a body from a shape, it preserves that array.

OCCTSwiftAIS's job:

1. Maintain a registry: `[InteractiveObject.id: (Shape, ViewportBody)]`.
2. Subscribe to OCCTSwiftViewport's pick events (it already publishes `(bodyIndex, triangleIndex)` from the GPU pick).
3. Look up the body's `faceIndices[triangleIndex]` to get the source face.
4. Translate to `OCCTSwift.Shape.subShapes(ofType: .face)[faceIndex]` to get the `TopoDS_Face` handle.
5. Wrap as a `SubShape.face(_, faceIndex:)` and feed into the selection state.

For edges and vertices the pattern is similar but needs a separate buffer in `ViewportBody` — likely `edgeIndices` and `vertexIndices`. **Coordinate with OCCTSwiftViewport on adding those.** They probably belong in OCCTSwiftViewport (so the renderer knows about them) with `OCCTSwiftTools` populating them.

### Hover / highlight rendering

OCCTSwiftViewport doesn't currently support per-sub-shape styling — only per-body. **Two routes**:

- **Cheap**: render the highlighted sub-shape as a separate overlay body (a small mesh extracted from the `TopoDS_Face`, drawn on top with depth offset and an outline shader). Works without renderer changes; some flicker possible at silhouettes.
- **Right**: extend OCCTSwiftViewport with a per-triangle uniform-buffer style overlay and let OCCTSwiftAIS write into it. Needs a small renderer change but eliminates flicker.

Start with the cheap route; upgrade if the visual quality is unacceptable.

### Manipulator widget

Three orthogonal axes + (later) screen-space rotation handles. Implementation:

- Geometry: pre-built per-axis arrow meshes (translate) or torus meshes (rotate). Store as static `ViewportBody` instances in the package.
- Picking: piggyback on viewport's GPU pick, with the widget's bodies registered in a separate "overlay" pass that ignores normal selection.
- Drag math: project mouse delta onto the active axis (translate) or onto the rotation plane (rotate). Quaternion lerp for smooth motion.
- Snap: clamp the projected delta to nearest multiple of `snapTranslate` / `snapRotateDeg`.
- Disposal: `uninstall()` removes the widget bodies + detaches event listeners.

### Dimensions

Hardest one because it needs **billboarded text in 3D space**. OCCTSwiftViewport already has measurement overlays (distance / angle / radius) per its README — first port-of-call is to read that code and see what's reusable.

Likely path: add a small `DimensionLayer` to OCCTSwiftViewport that handles label rendering (it already does this for measurements); OCCTSwiftAIS owns the `Dimension` types and feeds the layer.

### Selection survival across mutation

Critical correctness concern: `SubShape.face(_, faceIndex: 7)` only means "face 7" while the `Shape` is unchanged. If the app boolean-unions or filets the shape, face indices renumber.

**Don't try to track this transparently in v0.x.** Document it. When OCCTSwift's `History` API is in scope (it is — see `BRepGraph_HistoryRecord`), expose `InteractiveContext.remap(selection:after:)` that takes a history and returns a remapped selection. That's a v0.4+ feature.

### Async / concurrency

Use `@MainActor` aggressively. The selection state, hover state, and viewport binding all live on main. Geometry extraction (`ViewportBody.from`) can be async / off-thread but must not be on `MainActor`. Match OCCTSwiftViewport's existing isolation patterns — read its `ViewportController` first.

## Repo conventions

Match OCCTSwift's conventions exactly. Cribbed verbatim:

- **License**: LGPL 2.1 (matching OCCT). Copy from OCCTSwift.
- **swift-tools-version**: 6.1. Language mode: `.v6`.
- **Platforms**: `.iOS(.v18)`, `.macOS(.v15)`, `.visionOS(.v1)`, `.tvOS(.v18)`. (Higher of OCCTSwift / OCCTSwiftViewport floors.)
- **Tests**: Swift Testing (`@Suite` / `@Test` / `#expect`). Never `#expect(x != nil); #expect(x!.field)` — Swift Testing doesn't short-circuit. Always `if let x { #expect(x.field) }`.
- **Test naming**: `@Test func` names must NOT shadow API method names used inside the test body. Prefix with `t_` or use descriptive English.
- **OCCT race**: tests that exercise OCCT geometry need `OCCT_SERIAL=1 swift test --parallel --num-workers 1` (NCollection container-overflow race on arm64 macOS).
- **Versioning**: pre-1.0, free to break. Tiny additive features = patch bump (x.y.z+1), not minor. Minor bumps for new public surface.
- **Release pattern**: every shipped version commits + pushes + tags + creates a GitHub release with notes. Release notes go in `docs/CHANGELOG.md`.
- **README**: shields.io SPI badges (Swift versions / platforms / license), install snippet pinning to most recent semver, "Supported Platforms" table, link to ecosystem repos.
- **CODE_OF_CONDUCT.md**: short pointer to Contributor Covenant 2.1, **never inline the full text** — Anthropic's content filter blocks it.
- **`.spi.yml`**: SPI build matrix for Swift 6.0 / 6.1 / 6.2 / 6.3 + iOS, with `documentation_targets: [OCCTSwiftAIS]`. Submission to swiftpackageindex.com is gated on v1.0.0.

## Distribution

This repo does **not** ship a binary. Pure Swift package. Ships its own visual assets (manipulator meshes, dimension fonts) as bundle resources via `.process(...)` in Package.swift.

```swift
// downstream Package.swift dependencies
.package(url: "https://github.com/gsdali/OCCTSwiftAIS.git",   from: "0.1.0"),
```

OCCTSwiftAIS transitively brings OCCTSwiftTools → OCCTSwift + OCCTSwiftViewport.

## Tests

At minimum:

- Unit: `InteractiveContext.display(box) → pick at (x, y) → SubShape.face(...)` round-trip.
- Unit: selection set arithmetic — adding the same sub-shape twice is idempotent; clearing empties the set; mode change clears.
- Unit: Manipulator translate produces expected `simd_float4x4` for a known mouse-delta on screen-aligned axis.
- Unit: Snap rounds to nearest grid step.
- Unit: `LinearDimension(from: vertex, to: vertex)` produces correct anchor points and label text.
- Integration: load a small STEP file, display it, click on every face, confirm we get `count == nbFaces` distinct selections.

## Sequencing — first four releases

1. **v0.1.0 — Selection-from-topology only.** `InteractiveContext`, `display(_:)`, `select(_:)`, body + face selection only (edges / vertices deferred). Hover state via OCCTSwiftViewport's existing pick. Highlight via cheap-route overlay. ~2-3 weeks.
2. **v0.2.0 — Manipulator widget (translate).** Three-axis translate gizmo with snap. ~2 weeks.
3. **v0.3.0 — Manipulator widget (rotate) + edge / vertex selection.** Rotate gizmo + ViewportBody buffer extensions. ~2-3 weeks.
4. **v0.4.0 — Linear dimensions.** Linear dimension with leader lines, billboarded label. ~3 weeks.
5. **v0.5.0 — Angular and radial dimensions.** ~2 weeks.
6. **v0.6.0+ — Standard objects (Trihedron, WorkPlane, Axis, PointCloud), highlight via renderer extension, history-based selection remap.**

After v0.5 the surface is essentially complete; v0.6 onward is polish + power features.

## Coordinations needed

This repo necessarily drives small changes in two siblings:

- **OCCTSwiftViewport** — needs (a) per-sub-shape highlight overlay (v0.1 cheap route, then renderer-backed in v0.6), (b) `edgeIndices` and `vertexIndices` buffer fields on `ViewportBody` (v0.3), (c) widget overlay pass that bypasses normal pick (v0.2). Open issues against that repo as v0.1 lands.
- **OCCTSwiftTools** — needs to populate `edgeIndices` / `vertexIndices` buffers when extracting from `Shape` (v0.3). And pass-through metadata for dimension targeting (v0.4).
- **OCCTSwift** — `BRepGraph_HistoryRecord` lookup helpers for the v0.6 selection-remap. Already largely in place from v0.157 onwards.

## Ecosystem context to read before coding

- `~/Projects/OCCTSwift/CLAUDE.md`
- `~/Projects/OCCTSwift/docs/visualization-research.md` — the *why* doc
- `~/Projects/OCCTSwift/docs/platform-expansion.md`
- `~/Projects/OCCTSwift/docs/CHANGELOG.md` — recent OCCTSwift work
- `~/Projects/OCCTSwiftViewport/README.md` — what the renderer already provides
- `~/Projects/OCCTSwiftViewport/Sources/OCCTSwiftViewport/` — read `MetalViewportView`, `ViewportController`, `Picker`
- `~/Projects/OCCTSwiftTools/SPEC.md` — sibling spec
- `~/.claude/projects/-Users-elb-Projects-OCCTSwift/memory/MEMORY.md`

## What is explicitly out of scope

- Replacing OCCT's TKOpenGl with a Metal driver. (See `OCCTSwift/docs/visualization-research.md` — explicitly rejected, this repo exists *because* of that decision.)
- Ray-traced rendering. Use [CADRays](https://github.com/Open-Cascade-SAS/CADRays) separately if needed.
- Animation timelines, IK, physics. Not a CAD viewer concern.
- Multi-document support. One `InteractiveContext` per `ViewportController`; multi-doc is an app-level concern.
- Print / PDF export. Belongs in OCCTSwiftViewport's measurement / annotation export path.
- Linux / Windows / Android — see `OCCTSwift/docs/platform-expansion.md`.
- Apple Watch.
