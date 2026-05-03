import Foundation
import OCCTSwift

/// How `InteractiveContext.remap` handles sub-shapes whose original node has
/// no derivatives in the post-mutation graph.
///
/// **Caveat:** `TopologyGraph.findDerived(_:)` returns an empty list both for
/// "node not mentioned in any history record" *and* for "node explicitly
/// recorded as deleted (replacements: `[]`)". The two cases aren't
/// distinguishable through the current OCCTSwift surface, so:
///
/// - `.dropMissing` treats both the same way — it drops, which is correct for
///   deletions and conservative for unmentioned nodes.
/// - `.keepUnchanged` keeps both — which is correct for unmentioned nodes
///   that are presumed unchanged, and **incorrect** for explicitly-deleted
///   nodes. Use `.keepUnchanged` only when you know the operation didn't
///   delete anything (attribute-only edits, in-place transforms).
public enum RemapStrategy: Sendable {
    case dropMissing
    case keepUnchanged
}

extension InteractiveContext {

    /// Remap a `Selection` whose sub-shape indices were captured against an
    /// earlier shape state, using the history records on a `TopologyGraph`
    /// built from the post-mutation shape, into a new `Selection` whose
    /// indices apply against `newObject`.
    ///
    /// For each sub-shape the remap walks `graph.findDerived(of:)`:
    ///
    /// - **1 → 1** (face modified in place): the result has the new index.
    /// - **1 → N** (e.g. an edge split by a fillet): the result expands into
    ///   N sub-shapes, one per derived node.
    /// - **1 → 0** (deleted): handled per `strategy`.
    ///
    /// `.body(_)` sub-shapes always rebind to `newObject` — the body-level
    /// concept is identity-stable across mutations.
    ///
    /// - Parameters:
    ///   - selection: The pre-mutation selection.
    ///   - graph: A `TopologyGraph` built from the post-mutation shape with
    ///            history recorded for the operations between the two states.
    ///   - newObject: The `InteractiveObject` representing the post-mutation
    ///            shape in the scene. The remapped sub-shapes will reference it.
    ///   - strategy: How to handle sub-shapes the history doesn't mention.
    /// - Returns: A `Selection` against `newObject`.
    public func remap(
        _ selection: Selection,
        using graph: TopologyGraph,
        rebindingTo newObject: InteractiveObject,
        strategy: RemapStrategy = .dropMissing
    ) -> Selection {
        var result: Set<SubShape> = []
        for sub in selection.subshapes {
            switch sub {
            case .body:
                result.insert(.body(newObject))

            case .face(_, let idx):
                let newIndices = remapIndices(
                    originalIndex: idx, kind: .face, graph: graph, strategy: strategy
                )
                for i in newIndices where i < graph.faceCount {
                    result.insert(.face(newObject, faceIndex: i))
                }

            case .edge(_, let idx):
                let newIndices = remapIndices(
                    originalIndex: idx, kind: .edge, graph: graph, strategy: strategy
                )
                for i in newIndices where i < graph.edgeCount {
                    result.insert(.edge(newObject, edgeIndex: i))
                }

            case .vertex(_, let idx):
                let newIndices = remapIndices(
                    originalIndex: idx, kind: .vertex, graph: graph, strategy: strategy
                )
                for i in newIndices where i < graph.vertexCount {
                    result.insert(.vertex(newObject, vertexIndex: i))
                }
            }
        }
        return Selection(result)
    }

    private func remapIndices(
        originalIndex: Int,
        kind: TopologyGraph.NodeKind,
        graph: TopologyGraph,
        strategy: RemapStrategy
    ) -> [Int] {
        let original = TopologyGraph.NodeRef(kind: kind, index: originalIndex)
        let derived = graph.findDerived(of: original)
        if !derived.isEmpty {
            return derived.compactMap { d in d.kind == kind ? d.index : nil }
        }
        // No recorded derivatives. Strategy decides whether the original
        // index survives untouched or gets dropped.
        switch strategy {
        case .dropMissing:
            return []
        case .keepUnchanged:
            return [originalIndex]
        }
    }
}
