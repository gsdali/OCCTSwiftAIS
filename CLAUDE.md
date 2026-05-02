# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Read SPEC.md first

This repo is currently a **scaffold** — `Sources/OCCTSwiftAIS/` and `Tests/OCCTSwiftAISTests/` contain only `.gitkeep`. The implementation brief lives in [`SPEC.md`](SPEC.md) and is the source of truth for:

- Public API target shape (`InteractiveContext`, `SubShape`, `Selection`, `ManipulatorWidget`, `Dimension`, `Trihedron`/`WorkPlane`/`Axis`/`PointCloudPresentation`)
- Implementation guidance for the load-bearing pieces (selection-from-topology, hover/highlight rendering, manipulator math, dimensions)
- Release sequencing — which features land in v0.1, v0.2, … (do not implement out of order; later releases depend on sibling-repo changes that haven't shipped yet)
- Coordinations required in **OCCTSwiftViewport** (per-sub-shape highlight overlay; `edgeIndices`/`vertexIndices` buffers; widget overlay pass) and **OCCTSwiftTools** (populating those buffers)
- Explicit out-of-scope list (no TKMetal port, no ray tracing, no animation, no multi-doc, no Linux/Windows)

Do not start coding without reading SPEC.md end-to-end. Also read `~/Projects/OCCTSwift/docs/visualization-research.md` for *why* this layer exists rather than a TKMetal port — that decision shapes what is and isn't allowed here.

## Architectural position

```
Application
   ↑
OCCTSwiftAIS         ← this repo
   ↑
OCCTSwiftTools       ← bridge: Shape ↔ ViewportBody
   ↑      ↑
OCCTSwift  OCCTSwiftViewport
(B-Rep)    (Metal)
```

OCCTSwiftAIS depends only on **OCCTSwiftTools** and pulls OCCTSwift + OCCTSwiftViewport transitively. It adds **no shaders or render passes** — all rendering goes through OCCTSwiftViewport's existing `MetalViewportView` / `ViewportController`. The package's job is the high-level scene-management semantics OCCT users expect: selection-from-topology, manipulator widgets, dimension annotations, standard scene objects.

The selection-from-topology mapping is the load-bearing piece: GPU pick from OCCTSwiftViewport returns `(bodyIndex, triangleIndex)`, OCCTSwiftAIS looks up `ViewportBody.faceIndices[triangleIndex]` and translates back to a `TopoDS_Face` handle via `OCCTSwift.Shape.subShapes(ofType:)`. See SPEC.md §"Selection-from-topology — the load-bearing piece".

## Build & test

```bash
swift build
swift test

# OCCT geometry tests need serial execution (NCollection container-overflow race
# on arm64 macOS — same workaround as upstream OCCTSwift):
OCCT_SERIAL=1 swift test --parallel --num-workers 1

# Single test:
swift test --filter OCCTSwiftAISTests.<TestName>
```

Toolchain floor: **swift-tools-version 6.1**, Swift language mode `.v6`. Platforms: iOS 18 / macOS 15 / visionOS 1 / tvOS 18 (matches the higher of OCCTSwift / OCCTSwiftViewport).

## Conventions inherited from OCCTSwift

These are **not** generic best practices — they are project rules cribbed verbatim from the sibling repo. Follow them:

- **Tests use Swift Testing** (`@Suite` / `@Test` / `#expect`). Swift Testing does **not** short-circuit, so `#expect(x != nil); #expect(x!.field)` will crash when `x` is nil. Always pattern-match: `if let x { #expect(x.field == ...) }`.
- **`@Test func` names must not shadow API method names** used inside the test body. Prefix with `t_` or use a descriptive English name.
- **License is LGPL 2.1** (matches OCCT). Don't relicense.
- **Versioning is pre-1.0**, free to break. Tiny additive features → patch bump (`x.y.z+1`), not minor. New public surface → minor bump.
- **Release pattern**: every shipped version commits + pushes + tags + creates a GitHub release. Release notes go in `docs/CHANGELOG.md` (does not yet exist; create when first release ships).
- **`CODE_OF_CONDUCT.md`** is a short pointer to Contributor Covenant 2.1 — **never inline the full text** (Anthropic's content filter blocks it).
- **`.spi.yml`** drives the SPI build matrix (Swift 6.0 / 6.1 / 6.2 / 6.3 + iOS); SPI submission is gated on v1.0.0.

## Concurrency

`@MainActor` aggressively on user-facing API: `InteractiveContext`, selection state, hover state, viewport binding, `ManipulatorWidget`. Heavy geometry work (`ViewportBody.from(_:)`) is async / off-main and must **not** be `@MainActor`. Match OCCTSwiftViewport's `ViewportController` isolation patterns — read that file before introducing new actor boundaries.

## Distribution

Pure Swift package — **no binary xcframework**. Visual assets (manipulator meshes, dimension fonts) ship as bundle resources via `.process(...)` in `Package.swift` when the relevant features land.
