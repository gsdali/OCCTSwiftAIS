import Testing
import OCCTSwift
import OCCTSwiftViewport
@testable import OCCTSwiftAIS

@MainActor
@Suite("Remap")
struct RemapTests {

    private func makeContext() -> InteractiveContext {
        InteractiveContext(viewport: ViewportController())
    }

    private func makeBox() throws -> OCCTSwift.Shape {
        try #require(OCCTSwift.Shape.box(width: 4, height: 4, depth: 4))
    }

    private func makeGraph(of shape: OCCTSwift.Shape) throws -> TopologyGraph {
        let g = try #require(TopologyGraph(shape: shape, parallel: false))
        g.isHistoryEnabled = true
        return g
    }

    // MARK: - Body remapping

    @Test func t_remap_body_alwaysRebindsToNewObject() throws {
        let ctx = makeContext()
        let oldShape = try makeBox()
        let oldObj = ctx.display(oldShape)
        let newShape = try makeBox()
        let newObj = ctx.display(newShape)
        let graph = try makeGraph(of: newShape)

        let old = Selection([.body(oldObj)])
        let remapped = ctx.remap(old, using: graph, rebindingTo: newObj)

        #expect(remapped.subshapes == [.body(newObj)])
    }

    // MARK: - dropMissing strategy (default)

    @Test func t_remap_dropMissing_dropsFaceWithNoHistory() throws {
        let ctx = makeContext()
        let oldShape = try makeBox()
        let oldObj = ctx.display(oldShape)
        let newShape = try makeBox()
        let newObj = ctx.display(newShape)
        let graph = try makeGraph(of: newShape)

        let old = Selection([.face(oldObj, faceIndex: 0)])
        let remapped = ctx.remap(old, using: graph, rebindingTo: newObj)

        #expect(remapped.isEmpty, "no recorded derivatives + dropMissing → empty")
    }

    @Test func t_remap_keepUnchanged_preservesIndexWhenInRange() throws {
        let ctx = makeContext()
        let oldShape = try makeBox()
        let oldObj = ctx.display(oldShape)
        let newShape = try makeBox()
        let newObj = ctx.display(newShape)
        let graph = try makeGraph(of: newShape)

        let old = Selection([.face(oldObj, faceIndex: 0)])
        let remapped = ctx.remap(old, using: graph, rebindingTo: newObj, strategy: .keepUnchanged)

        #expect(remapped.subshapes == [.face(newObj, faceIndex: 0)])
    }

    @Test func t_remap_keepUnchanged_dropsIndexOutOfRange() throws {
        let ctx = makeContext()
        let oldShape = try makeBox()
        let oldObj = ctx.display(oldShape)
        let newShape = try makeBox()
        let newObj = ctx.display(newShape)
        let graph = try makeGraph(of: newShape)

        // Face index way past the new graph's faceCount.
        let old = Selection([.face(oldObj, faceIndex: 9_999)])
        let remapped = ctx.remap(old, using: graph, rebindingTo: newObj, strategy: .keepUnchanged)

        #expect(remapped.isEmpty)
    }

    // MARK: - Recorded history

    @Test func t_remap_oneToOne_followsRecordedDerivative() throws {
        let ctx = makeContext()
        let oldShape = try makeBox()
        let oldObj = ctx.display(oldShape)
        let newShape = try makeBox()
        let newObj = ctx.display(newShape)
        let graph = try makeGraph(of: newShape)

        graph.recordHistory(
            operationName: "test-rename-face-0-to-3",
            original: TopologyGraph.NodeRef(kind: .face, index: 0),
            replacements: [TopologyGraph.NodeRef(kind: .face, index: 3)]
        )

        let old = Selection([.face(oldObj, faceIndex: 0)])
        let remapped = ctx.remap(old, using: graph, rebindingTo: newObj)
        #expect(remapped.subshapes == [.face(newObj, faceIndex: 3)])
    }

    @Test func t_remap_oneToMany_expandsToAllReplacements() throws {
        let ctx = makeContext()
        let oldShape = try makeBox()
        let oldObj = ctx.display(oldShape)
        let newShape = try makeBox()
        let newObj = ctx.display(newShape)
        let graph = try makeGraph(of: newShape)

        // Simulate an edge split: old edge 0 → two NEW edges 3 and 7.
        // (We avoid self-references in the replacement list — `findDerived`
        // walks forward and dedupes self-loops, so `[0, 7]` would collapse to
        // `[7]` and not what we want to verify here.)
        graph.recordHistory(
            operationName: "test-split-edge-0",
            original: TopologyGraph.NodeRef(kind: .edge, index: 0),
            replacements: [
                TopologyGraph.NodeRef(kind: .edge, index: 3),
                TopologyGraph.NodeRef(kind: .edge, index: 7),
            ]
        )

        let old = Selection([.edge(oldObj, edgeIndex: 0)])
        let remapped = ctx.remap(old, using: graph, rebindingTo: newObj)
        let expected: Set<SubShape> = [
            .edge(newObj, edgeIndex: 3),
            .edge(newObj, edgeIndex: 7),
        ]
        #expect(remapped.subshapes == expected)
    }

    @Test func t_remap_oneToZero_dropsDeletedNode_underDropMissing() throws {
        let ctx = makeContext()
        let oldShape = try makeBox()
        let oldObj = ctx.display(oldShape)
        let newShape = try makeBox()
        let newObj = ctx.display(newShape)
        let graph = try makeGraph(of: newShape)

        // Empty replacements = the node was deleted.
        graph.recordHistory(
            operationName: "test-delete-face-2",
            original: TopologyGraph.NodeRef(kind: .face, index: 2),
            replacements: []
        )

        // The `findDerived` API doesn't distinguish "no history" from "explicit
        // empty replacement list" — both come back empty. So a deletion only
        // looks like a deletion under `.dropMissing`. With `.keepUnchanged`
        // we'd preserve the index, which is the documented limitation.
        let old = Selection([.face(oldObj, faceIndex: 2)])
        let remapped = ctx.remap(old, using: graph, rebindingTo: newObj)
        #expect(remapped.isEmpty)
    }

    @Test func t_remap_filtersByKind_evenWhenHistoryCrossesKinds() throws {
        // If the history maps a face → edges (unusual but legal), the remap
        // should skip the cross-kind entries — a Selection.face slot can only
        // hold a face index.
        let ctx = makeContext()
        let oldShape = try makeBox()
        let oldObj = ctx.display(oldShape)
        let newShape = try makeBox()
        let newObj = ctx.display(newShape)
        let graph = try makeGraph(of: newShape)

        graph.recordHistory(
            operationName: "test-degenerate-face-to-edges",
            original: TopologyGraph.NodeRef(kind: .face, index: 0),
            replacements: [
                TopologyGraph.NodeRef(kind: .edge, index: 1),
                TopologyGraph.NodeRef(kind: .edge, index: 2),
            ]
        )

        let old = Selection([.face(oldObj, faceIndex: 0)])
        let remapped = ctx.remap(old, using: graph, rebindingTo: newObj)
        #expect(remapped.isEmpty)
    }

    @Test func t_remap_mixedKindSelection_remapsEachIndependently() throws {
        let ctx = makeContext()
        let oldShape = try makeBox()
        let oldObj = ctx.display(oldShape)
        let newShape = try makeBox()
        let newObj = ctx.display(newShape)
        let graph = try makeGraph(of: newShape)

        graph.recordHistory(
            operationName: "test-face",
            original: TopologyGraph.NodeRef(kind: .face, index: 0),
            replacements: [TopologyGraph.NodeRef(kind: .face, index: 4)]
        )
        graph.recordHistory(
            operationName: "test-edge",
            original: TopologyGraph.NodeRef(kind: .edge, index: 1),
            replacements: [TopologyGraph.NodeRef(kind: .edge, index: 7)]
        )

        let old = Selection([
            .body(oldObj),
            .face(oldObj, faceIndex: 0),
            .edge(oldObj, edgeIndex: 1),
        ])
        let remapped = ctx.remap(old, using: graph, rebindingTo: newObj)

        #expect(remapped.subshapes.count == 3)
        #expect(remapped.subshapes.contains(.body(newObj)))
        #expect(remapped.subshapes.contains(.face(newObj, faceIndex: 4)))
        #expect(remapped.subshapes.contains(.edge(newObj, edgeIndex: 7)))
    }

    @Test func t_remap_emptySelection_returnsEmpty() throws {
        let ctx = makeContext()
        let newShape = try makeBox()
        let newObj = ctx.display(newShape)
        let graph = try makeGraph(of: newShape)
        let remapped = ctx.remap(Selection(), using: graph, rebindingTo: newObj)
        #expect(remapped.isEmpty)
    }
}
