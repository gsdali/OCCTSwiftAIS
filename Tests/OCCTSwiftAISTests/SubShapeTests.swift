import Testing
import OCCTSwift
@testable import OCCTSwiftAIS

@Suite("SubShape")
struct SubShapeTests {

    @Test func t_sameObjectAndIndex_isEqual() throws {
        let shape = try #require(Shape.box(width: 10, height: 5, depth: 3))
        let obj = InteractiveObject(shape: shape)
        let a = SubShape.face(obj, faceIndex: 2)
        let b = SubShape.face(obj, faceIndex: 2)
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
    }

    @Test func t_differentIndex_notEqual() throws {
        let shape = try #require(Shape.box(width: 10, height: 5, depth: 3))
        let obj = InteractiveObject(shape: shape)
        #expect(SubShape.face(obj, faceIndex: 0) != SubShape.face(obj, faceIndex: 1))
    }

    @Test func t_differentCases_notEqual() throws {
        let shape = try #require(Shape.box(width: 10, height: 5, depth: 3))
        let obj = InteractiveObject(shape: shape)
        #expect(SubShape.body(obj) != SubShape.face(obj, faceIndex: 0))
        #expect(SubShape.face(obj, faceIndex: 0) != SubShape.edge(obj, edgeIndex: 0))
    }

    @Test func t_differentObjects_notEqual() throws {
        let shapeA = try #require(Shape.box(width: 1, height: 1, depth: 1))
        let shapeB = try #require(Shape.box(width: 1, height: 1, depth: 1))
        let a = InteractiveObject(shape: shapeA)
        let b = InteractiveObject(shape: shapeB)
        #expect(SubShape.body(a) != SubShape.body(b))
    }

    @Test func t_object_extracts_underlyingObject() throws {
        let shape = try #require(Shape.box(width: 1, height: 1, depth: 1))
        let obj = InteractiveObject(shape: shape)
        #expect(SubShape.face(obj, faceIndex: 3).object == obj)
        #expect(SubShape.body(obj).object == obj)
    }
}
