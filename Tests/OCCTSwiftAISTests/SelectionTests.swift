import Testing
import OCCTSwift
@testable import OCCTSwiftAIS

@Suite("Selection")
struct SelectionTests {

    @Test func t_empty_byDefault() {
        let s = Selection()
        #expect(s.isEmpty)
        #expect(s.count == 0)
        #expect(s.bodies.isEmpty)
        #expect(s.faces.isEmpty)
    }

    @Test func t_insertSameSubshapeTwice_isIdempotent() throws {
        let shape = try #require(Shape.box(width: 1, height: 1, depth: 1))
        let obj = InteractiveObject(shape: shape)
        let face = SubShape.face(obj, faceIndex: 0)
        let s = Selection([face, face, face])
        #expect(s.count == 1)
    }

    @Test func t_bodies_derivesFromSubshapes() throws {
        let shapeA = try #require(Shape.box(width: 1, height: 1, depth: 1))
        let shapeB = try #require(Shape.box(width: 2, height: 2, depth: 2))
        let a = InteractiveObject(shape: shapeA)
        let b = InteractiveObject(shape: shapeB)
        let s = Selection([
            .face(a, faceIndex: 0),
            .face(a, faceIndex: 1),
            .body(b),
        ])
        #expect(s.bodies == [a, b])
    }

    @Test func t_faces_resolveToFaceHandles() throws {
        let shape = try #require(Shape.box(width: 10, height: 5, depth: 3))
        let obj = InteractiveObject(shape: shape)
        let s = Selection([
            .face(obj, faceIndex: 0),
            .face(obj, faceIndex: 1),
            .body(obj),                 // should be excluded from .faces
        ])
        #expect(s.faces.count == 2)
    }

    @Test func t_faces_droppedWhenIndexOutOfRange() throws {
        let shape = try #require(Shape.box(width: 1, height: 1, depth: 1))
        let obj = InteractiveObject(shape: shape)
        let s = Selection([
            .face(obj, faceIndex: 0),
            .face(obj, faceIndex: 9999),
        ])
        #expect(s.faces.count == 1)
    }
}
