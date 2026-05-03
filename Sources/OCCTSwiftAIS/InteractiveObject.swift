import Foundation
import OCCTSwift

/// Erased reference to something currently displayed in an `InteractiveContext`.
///
/// Equality and hashing are by `id` only. Two `InteractiveObject`s with the same
/// id refer to the same logical scene entry even if their `Shape` was rebuilt.
public struct InteractiveObject: Hashable, Sendable {
    public let id: UUID
    public let shape: Shape

    public init(id: UUID = UUID(), shape: Shape) {
        self.id = id
        self.shape = shape
    }

    public static func == (lhs: InteractiveObject, rhs: InteractiveObject) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// A specific TopoDS sub-shape inside a displayed `InteractiveObject`, or the
/// whole body. Sub-shape indices are valid only while the underlying `Shape` is
/// unchanged — see SPEC.md §"Selection survival across mutation".
public enum SubShape: Hashable, Sendable {
    case body(InteractiveObject)
    case face(InteractiveObject, faceIndex: Int)
    case edge(InteractiveObject, edgeIndex: Int)
    case vertex(InteractiveObject, vertexIndex: Int)

    public var object: InteractiveObject {
        switch self {
        case .body(let o):          return o
        case .face(let o, _):       return o
        case .edge(let o, _):       return o
        case .vertex(let o, _):     return o
        }
    }
}
