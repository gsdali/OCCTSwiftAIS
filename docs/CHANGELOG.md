# Changelog

Most recent first. Pre-1.0: free to break; deprecations documented here.

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
