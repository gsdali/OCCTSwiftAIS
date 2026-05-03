# Changelog

Most recent first. Pre-1.0: free to break; deprecations documented here.

## v0.3.0 — 2026-05-03

Edge and vertex selection-from-topology — the second half of the v0.3 SPEC milestone (rotate manipulator already shipped in v0.2.2). Closes the headline "selection-from-topology" feature: face / edge / vertex picks from the GPU all round-trip to OCCTSwift handles.

**Behaviour:**

- `InteractiveContext.handlePick` dispatches on `PickResult.kind` from [OCCTSwiftViewport v0.55.0](https://github.com/gsdali/OCCTSwiftViewport/releases/tag/v0.55.0):
  - `.face` → `SubShape.face(obj, faceIndex:)` via `CADBodyMetadata.faceIndices` (unchanged behaviour).
  - `.edge` → `SubShape.edge(obj, edgeIndex:)` via `body.edgeIndices[primIdx]`.
  - `.vertex` → `SubShape.vertex(obj, vertexIndex:)` via `body.vertexIndices[primIdx]`.
- Picks of a kind not in `selectionMode` are ignored.
- `display(_:)` now populates `body.edgeIndices` (flattened from `metadata.edgePolylines`) and `body.vertices` / `body.vertexIndices` (positional, from `shape.vertices()`) so the renderer's edge / vertex pick passes have data to work with. **Workaround for** [OCCTSwiftTools#8](https://github.com/gsdali/OCCTSwiftTools/issues/8) — once Tools populates these directly during `shapeToBodyAndMetadata`, the AIS-side helper becomes a no-op (it early-outs when the arrays are already set).

**New public surface:**

- `Selection.vertices: [SIMD3<Double>]` — world-space positions of any `.vertex(...)` entries. Returns positions rather than a rich type because OCCTSwift exposes vertices as `SIMD3<Double>` values (no `Vertex` class).

**Dependencies:** floor raised to `OCCTSwiftTools` ≥ 0.4.0 (transitively `OCCTSwiftViewport` ≥ 0.55.0, `OCCTSwift` ≥ 0.168.0).

**Tests:** 12 new in `EdgeVertexSelection` covering display populating edge / vertex pick arrays; positional vertex indexing; `handlePick` dispatching face / edge / vertex correctly; mode-mismatched picks ignored; out-of-range primitive ignored; `Selection.vertices` filtering only `.vertex` cases and resolving to source positions; multi-mode replacement on subsequent picks of different kinds. Total: **107 across 9 suites**.

**SPEC milestone status:** `v0.3.0` per SPEC.md §"Sequencing" called for "Manipulator widget (rotate) + edge / vertex selection". Rotate shipped in v0.2.2; this release ships edge/vertex. v0.4.0 onward picks up linear / angular / radial dimensions.

## v0.2.4 — 2026-05-03

Standard scene objects per SPEC.md §"Standard objects". Each emits one or more `ViewportBody`s via `makeBodies()` that the caller appends to their `InteractiveContext.bodies`. They aren't selectable — they're visual aids only.

**New public types:**

- `Trihedron(at:axisLength:id:)` — three colored axis arrows (`ManipulatorWidget.Axis.color` palette) plus a small center sphere. Useful as a world-axes affordance.
- `WorkPlane(origin:normal:size:color:id:)` — semi-transparent quad in the plane perpendicular to `normal`. Two triangles, six indices.
- `Axis(from:to:color:radius:id:)` — thin cylinder between two world points; the `color` parameter is `SIMD3<Float>` to match SPEC, internally packed to `SIMD4<Float>(color, 1)`.
- `PointCloudPresentation(points:colors:pointRadius:defaultColor:id:)` — N small spheres tessellated into a **single** `ViewportBody` for efficiency. Per-point colors not yet supported (renderer doesn't expose per-vertex color attributes); first entry of `colors` becomes the cloud's uniform color, else `defaultColor`.

Each type has an `ownsBody(id:)` predicate so callers can remove all of an instance's bodies later via `context.bodies.removeAll { obj.ownsBody(id: $0.id) }`.

**New internal:** `StandardObjectGeometry` — pure-Swift mesh helpers (`makeQuad`, `makeCylinder`, `makeSphere`, `makeSpheresInOneBody`). Multiple-spheres-as-one-mesh keeps the body count low for moderate clouds.

**Tests:** 15 new in `StandardObjects` covering body counts, ID conventions, color application, geometry scaling with `axisLength` / `size`, normal correctness on the work-plane quad, zero-length axis edge case, color-from-first-entry on point cloud, empty-points no-op. Total: **95 across 8 suites**.

**Dependencies:** unchanged from v0.2.3.

## v0.2.3 — 2026-05-03

`.attachManipulator(_:)` SwiftUI view modifier — wraps a viewport view (e.g. `MetalViewportView`) with a `.highPriorityGesture(DragGesture)` that hit-tests the widget on touch-down and dispatches:

- **Widget hit:** `widget.beginDrag` / `updateDrag` / `endDrag` drives the translate or rotate transform.
- **Off-handle:** drags forward to `viewport.handleOrbit(translation:)` so the camera responds normally. `endOrbit(velocity: .zero)` on release.

Closes the loop on the manipulator UX — apps can now write `MetalViewportView(controller: ais.viewport, bodies: $ais.bodies).attachManipulator(myWidget)` instead of hand-rolling gesture wiring.

**New public surface:**

- `View.attachManipulator(_ widget: ManipulatorWidget) -> some View` — the modifier.
- `ManipulatorWidget.context: InteractiveContext?` (read-only) — exposes the installed context so the modifier can route camera-fallback drags through `widget.context?.viewport`.

**New internal:** `ManipulatorGestureCoordinator` factors the dispatch logic out of SwiftUI's gesture machinery so it's unit-testable. Pure-Swift; tracks `.idle` / `.widget(axis)` / `.camera` mode; exposes `onChanged(location:translation:in:)` and `onEnded()` entry points.

**Tests:** 11 new in `ManipulatorGestureCoordinator` suite covering `ndcFromPoint` math (center → 0; top-left → (-1, +1); bottom-right → (+1, -1); zero size → zero), mode transitions on hit / miss, drag forwarding to widget, orbit forwarding to controller, commit on widget-mode end, and graceful no-op when widget has no installed context. Total: **80 across 7 suites**.

**Dependencies:** unchanged from v0.2.2.

## v0.2.2 — 2026-05-03

`ManipulatorWidget.Mode.rotate` is wired up. Three torus-handle rings appear at install (X / Y / Z, in `Axis.color`); a click on a ring begins a rotation drag; the drag delta is the angle between the initial and current pick-ray-vs-ring-plane intersections, with `snapRotateDeg` rounding. The running transform is `T(pivot) * R(axis, θ) * T(-pivot)`, so the target rotates **around its centroid** (the box-bbox center) and the pivot itself stays fixed. The target body's `ViewportBody.transform` updates live, like translate mode.

Implemented entirely on `ManipulatorWidget` — no new public types or signatures. Translate-mode behavior is unchanged.

**New internal pieces:**

- `ManipulatorGeometry.makeRotationRing(id:pivot:axis:radius:tubeRadius:color:sides:tubeSides:)` — pure-Swift torus tessellation. `renderLayer = .overlay`, `pickLayer = .widget` like the arrow.
- Rotate drag math: pick-ray intersects the ring plane (perpendicular to `axis` through `pivot`); angle measured in a per-axis stable in-plane basis via `atan2`; angle delta wrapped to `(-π, π]` so a drag crossing the ±π seam doesn't jump 2π.
- New configurables: `rotateRingRadius`, `rotateTubeRadius`, `rotateHitTolerance`, `rotateAxisDotMin`. All have sensible defaults derived from `size` / `shaftRadius`.

**Limitations (matching the cheap-route geometry approach):**

- Rings are skipped from hit-testing when their plane is near-parallel to the view direction (`|dot(viewDir, axis)| < rotateAxisDotMin`). In a perfectly axis-on view, two of three rings degenerate to a line in screen space and become unpickable; rotate the camera slightly to recover. A renderer-side screen-space ellipse hit-test (or a CPU "drag along the projected ring tangent") would lift this; deferred to a later release.
- Rings stay anchored at the pivot rather than co-rotating with the target. This keeps the visual reference of "what axis am I rotating around" stable during a long drag. (Some CAD apps rotate the rings; leave that as opt-in if asked.)

**Tests:** 13 new in a `ManipulatorWidget rotate` suite. Total: 69 across 6 suites.

`v0.3.0` is reserved for the bundled rotate + edge/vertex selection milestone per SPEC.md §"Sequencing", waiting on [OCCTSwiftViewport#24](https://github.com/gsdali/OCCTSwiftViewport/issues/24).

**Dependencies:** unchanged from v0.2.1.

## v0.2.1 — 2026-05-03

`ManipulatorWidget` adopts the renderer-side primitives that landed in [OCCTSwiftViewport v0.52.0](https://github.com/gsdali/OCCTSwiftViewport/releases/tag/v0.52.0) (resolves OCCTSwiftViewport#23). No public API changes.

**Behaviour:**

- Arrow bodies set `renderLayer = .overlay` and `pickLayer = .widget`. The renderer draws them after the selection-outline pass with `depthCompareFunction = .always`, so manipulator handles stay visible (and grabbable) even when occluded by the target. Widget picks now flow through `viewport.widgetPickResult` instead of polluting `viewport.pickResult` — the previous id-prefix filter on `InteractiveContext.handlePick` is now redundant but harmless.
- Arrow geometry is built **once** at install (centered on origin in vertex space). Per-frame motion is applied via `ViewportBody.transform`; no more vertex-data churn during drag.
- The target body's transform updates **live** during drag — `body.transform = preInstallTransform * widget.transform`. Users see the body translate in real time, not just on `onCommit`. The pre-install transform is captured at `install(in:)` and restored on `uninstall()`, so the widget's running translation does not survive teardown.
- `install(in:)` against a target whose body already has a non-identity transform composes correctly: drags apply on top, uninstall restores the original.

**Dependencies:** floor raised to `OCCTSwiftTools` ≥ 0.3.0 (transitively `OCCTSwiftViewport` ≥ 0.52.0, `OCCTSwift` ≥ 0.168.0).

**Tests:** 5 new (`t_arrowsAreOverlayLayer`, `t_arrowsAreWidgetPickLayer`, `t_dragUpdatesTargetBodyTransformLive`, `t_uninstall_restoresTargetBodyTransform`, `t_install_capturesPreExistingTargetTransform`). Total: 56 across 5 suites.

## v0.2.0 — 2026-05-03

Translate manipulator widget — the data + math layer of SPEC.md §"Manipulator widget". `ManipulatorWidget` ships an axis-arrow gizmo for translating an `InteractiveObject`: install adds three colored arrow bodies to the scene, hit-test maps an NDC click to the picked axis (or `nil`), drag math projects the pick ray onto the axis line via closest-point-between-two-lines, with optional snap-to-step. Callbacks (`onChange` / `onCommit`) report the running and committed `simd_float4x4`.

**New public API:**

- `final class ManipulatorWidget: ObservableObject` (`@MainActor`) — `init(target:mode:)`, `install(in:)`, `uninstall()`, `hitTest(ndc:camera:aspect:)`, `beginDrag(axis:ndc:camera:aspect:)`, `updateDrag(ndc:camera:aspect:)`, `endDrag(commit:)`, `reset()`. Configurables: `size`, `shaftRadius`, `hitNDCTolerance`, `snapTranslate`, `snapRotateDeg`. Observable: `transform`, `isInstalled`, `activeAxis`. Callbacks: `onChange`, `onCommit`.
- `enum ManipulatorWidget.Mode` — `.translate` (live), `.rotate` / `.scale` (placeholders for v0.3+).
- `enum ManipulatorWidget.Axis` — `.x` / `.y` / `.z` with `direction` and `color` accessors.

**Wiring pattern (NDC + camera state in, transform out — gestures owned by the caller):**

```swift
let widget = ManipulatorWidget(target: obj)
widget.snapTranslate = 0.25
widget.install(in: ais)

// In your gesture handler:
let ndc = ndcFromTouchPoint(...)
if !widget.isDragging,
   let axis = widget.hitTest(ndc: ndc, camera: ais.viewport.cameraState, aspect: ais.viewport.lastAspectRatio) {
    widget.beginDrag(axis: axis, ndc: ndc, camera: ais.viewport.cameraState, aspect: ais.viewport.lastAspectRatio)
}
widget.updateDrag(ndc: ndc, camera: ais.viewport.cameraState, aspect: ais.viewport.lastAspectRatio)
// On gesture end:
widget.endDrag(commit: true)
```

**Behaviour:**

- Widget bodies are tagged `ais.widget.<UUID>.<x|y|z>`. They appear in `bodies` like any other geometry but are excluded from the user selection stream automatically — `InteractiveContext.handlePick` only registers picks for bodies that came through `display(_:)`.
- During drag, the running transform is applied to the gizmo arrows so the user sees their input. The target body is **not** moved — the renderer doesn't yet expose a per-body transform; consumers should apply the committed transform to the underlying `Shape` themselves on `onCommit`. See [OCCTSwiftViewport#23](https://github.com/gsdali/OCCTSwiftViewport/issues/23) for the renderer-side work that will eventually unlock live target updates plus on-top arrow rendering and a native widget-pick layer.
- `mode = .rotate` / `.scale` are accepted by `init` for forward compatibility but currently render translate handles only. Real rotate handles ship in v0.3 alongside edge / vertex selection.

**Internal additions on `InteractiveContext`** (used by manipulators and future internal subsystems):

- `bodyID(for:)`, `sourceBody(for:)`, `appendInternalBody(_:)`, `removeInternalBodies(where:)`. Internal access only — these are not part of the public API surface.

**Tests:** 14 new in `ManipulatorWidget` suite. Total: 51 across 5 suites. Hit-test, drag projection, snap-to-step, gizmo follows transform, callbacks fire, widget bodies don't pollute user picks.

**Dependencies:** unchanged (`OCCTSwiftTools` ≥ 0.1.0).

## v0.1.0 — 2026-05-03

Initial release. Selection-from-topology lands as the headline feature: GPU pick → `(bodyIndex, triangleIndex)` from OCCTSwiftViewport is mapped, via OCCTSwiftTools-supplied `CADBodyMetadata.faceIndices`, to a `TopoDS_Face` handle inside the displayed `Shape`. The cheap-route highlight overlay from SPEC.md §"Hover / highlight rendering" is implemented — selected faces render as a separate sub-mesh `ViewportBody`, vertices pushed along their normal by `0.0005 × bbox-diagonal` to win the depth fight, in `HighlightStyle.selectionColor`.

**Public API** (see [SPEC.md](../SPEC.md) §"Public API target shape" for the v0.x → v1.0 trajectory):

- `final class InteractiveContext: ObservableObject` (`@MainActor`) — `init(viewport:)`, `display(_:style:)`, `remove(_:)`, `removeAll()`, `select(_:)`, `deselect(_:)`, `clearSelection()`, `setStyle(_:for:)`, `setHighlightStyle(_:)`. Observable: `bodies` (bind to `MetalViewportView`), `selection`, `hover`, `selectionMode`.
- `struct InteractiveObject: Hashable, Sendable` — UUID-identity scene handle wrapping a `Shape`.
- `enum SubShape: Hashable, Sendable` — `.body`, `.face(_, faceIndex:)`, `.edge(_, edgeIndex:)`, `.vertex(_, vertexIndex:)`.
- `struct Selection: Hashable, Sendable` — set of `SubShape`s with derived `bodies`, `faces`, `edges`.
- `enum SelectionMode: Hashable, Sendable` — `.body`, `.face`, `.edge`, `.vertex`.
- `struct PresentationStyle: Sendable, Equatable` — `color`, `transparency`, `displayMode`, `visible`, plus `.default` / `.ghosted` / `.highlighted` / `.hovered` presets.
- `struct HighlightStyle: Sendable, Equatable` — `selectionColor`, `hoverColor`, `outlineWidth`, plus `.default`.
- `enum DisplayMode: Hashable, Sendable` — `.shaded`, `.wireframe`, `.shadedWithEdges`.

**Behaviour:**
- A pick event from the viewport **replaces** the current selection with the picked sub-shape; `select(_:)` / `deselect(_:)` are additive (`Set` semantics, idempotent).
- Changing `selectionMode` clears the current selection.
- Body-level selection routes to `viewport.selectedBodyIDs` so the renderer's built-in body highlight applies; face-level selection produces overlay bodies tagged `ais.overlay.sel.<UUID>` and kept at the trailing end of `bodies` so subsequently displayed bodies don't render in front of them.
- Empty-space picks (`pickResult == nil`) leave the selection unchanged.

**Scope (matching SPEC.md §"Sequencing"):** body + face selection only. Edge / vertex selection deferred to v0.3 (requires `edgeIndices` / `vertexIndices` buffers in OCCTSwiftViewport's `ViewportBody`). Manipulator widget deferred to v0.2. Dimensions deferred to v0.4+.

**Known limitations:**
- Face-level *hover* is not surfaced — OCCTSwiftViewport currently publishes only `hoveredBodyID`. Body-level hover works.
- Highlight overlay uses normal-offset to fight the depth test; minor flicker at silhouette edges is possible (acknowledged in SPEC §"Hover / highlight rendering"). The renderer-backed overlay path is scheduled for v0.6.
- Selection survival across `Shape` mutation is not implemented — sub-shape indices are valid only while the underlying `Shape` is unchanged. History-based remap is scheduled for v0.4+.

**Dependencies:** `OCCTSwiftTools` ≥ 0.1.0 (transitively pulls `OCCTSwift` 0.167.0 and `OCCTSwiftViewport` 0.51.0).

**Tests:** 37 across 4 suites (`SubShape`, `Selection`, `InteractiveContext`, `HighlightOverlay`). Run with `OCCT_SERIAL=1 swift test --parallel --num-workers 1`.
