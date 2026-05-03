# Changelog

Most recent first. Pre-1.0: free to break; deprecations documented here.

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
