import Foundation
import OCCTSwift

/// Categories of sub-shape that can be selected.
public enum SelectionMode: Hashable, Sendable {
    case body
    case face
    case edge
    case vertex
}

/// Snapshot of selected sub-shapes.
public struct Selection: Hashable, Sendable {
    public let subshapes: Set<SubShape>

    public init(_ subshapes: Set<SubShape> = []) {
        self.subshapes = subshapes
    }

    public var isEmpty: Bool { subshapes.isEmpty }
    public var count: Int { subshapes.count }

    /// Distinct interactive objects represented in this selection.
    public var bodies: Set<InteractiveObject> {
        Set(subshapes.map(\.object))
    }

    /// Concrete `Face` handles for any `.face(...)` entries. Order is unspecified.
    /// Faces whose index no longer resolves on the source `Shape` are omitted.
    public var faces: [Face] {
        subshapes.compactMap { sub in
            guard case .face(let obj, let idx) = sub else { return nil }
            guard let faceShape = obj.shape.subShape(type: .face, index: idx) else { return nil }
            return Face(faceShape)
        }
    }

    /// Concrete `Edge` handles for any `.edge(...)` entries. Order is unspecified.
    public var edges: [Edge] {
        subshapes.compactMap { sub in
            guard case .edge(let obj, let idx) = sub else { return nil }
            guard let edgeShape = obj.shape.subShape(type: .edge, index: idx) else { return nil }
            return Edge(edgeShape)
        }
    }
}
