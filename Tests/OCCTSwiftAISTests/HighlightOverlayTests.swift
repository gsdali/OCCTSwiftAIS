import Testing
import simd
import OCCTSwift
import OCCTSwiftViewport
@testable import OCCTSwiftAIS

@MainActor
@Suite("HighlightOverlay")
struct HighlightOverlayTests {

    private func makeContext() -> InteractiveContext {
        InteractiveContext(viewport: ViewportController())
    }

    private func makeBox() throws -> Shape {
        try #require(Shape.box(width: 10, height: 5, depth: 3))
    }

    private func overlayBodies(_ ctx: InteractiveContext) -> [ViewportBody] {
        ctx.bodies.filter { $0.id.hasPrefix("ais.overlay.sel.") }
    }

    // MARK: - Face overlays

    @Test func t_faceSelection_addsOverlayBody() throws {
        let ctx = makeContext()
        ctx.selectionMode = [.face]
        let obj = ctx.display(try makeBox())

        ctx.select(.face(obj, faceIndex: 0))

        let overlays = overlayBodies(ctx)
        #expect(overlays.count == 1)
        let overlay = try #require(overlays.first)
        #expect(overlay.indices.count > 0)
        #expect(overlay.faceIndices.allSatisfy { $0 == 0 })
    }

    @Test func t_faceSelection_overlayUsesHighlightColor() throws {
        let ctx = makeContext()
        ctx.selectionMode = [.face]
        let obj = ctx.display(try makeBox())
        ctx.setHighlightStyle(HighlightStyle(
            selectionColor: SIMD3<Float>(0.2, 0.4, 0.6),
            hoverColor: .zero,
            outlineWidth: 1
        ))
        ctx.select(.face(obj, faceIndex: 0))
        let overlay = try #require(overlayBodies(ctx).first)
        #expect(abs(overlay.color.x - 0.2) < 0.001)
        #expect(abs(overlay.color.y - 0.4) < 0.001)
        #expect(abs(overlay.color.z - 0.6) < 0.001)
    }

    @Test func t_setHighlightStyle_updatesExistingOverlayColor() throws {
        let ctx = makeContext()
        ctx.selectionMode = [.face]
        let obj = ctx.display(try makeBox())
        ctx.select(.face(obj, faceIndex: 0))
        let initialColor = try #require(overlayBodies(ctx).first?.color)

        ctx.setHighlightStyle(HighlightStyle(
            selectionColor: SIMD3<Float>(0, 1, 0),
            hoverColor: .zero,
            outlineWidth: 1
        ))
        let newColor = try #require(overlayBodies(ctx).first?.color)
        #expect(newColor != initialColor)
        #expect(abs(newColor.y - 1) < 0.001)
    }

    @Test func t_clearSelection_removesOverlay() throws {
        let ctx = makeContext()
        ctx.selectionMode = [.face]
        let obj = ctx.display(try makeBox())
        ctx.select(.face(obj, faceIndex: 0))
        #expect(overlayBodies(ctx).count == 1)

        ctx.clearSelection()
        #expect(overlayBodies(ctx).isEmpty)
    }

    @Test func t_multiFaceSelection_sameBody_groupsIntoSingleOverlay() throws {
        let ctx = makeContext()
        ctx.selectionMode = [.face]
        let obj = ctx.display(try makeBox())
        ctx.select(.face(obj, faceIndex: 0))
        ctx.select(.face(obj, faceIndex: 1))

        let overlays = overlayBodies(ctx)
        #expect(overlays.count == 1)
        let overlay = try #require(overlays.first)
        let faces = Set(overlay.faceIndices.map(Int.init))
        #expect(faces == [0, 1])
    }

    @Test func t_facesAcrossTwoBodies_producesTwoOverlays() throws {
        let ctx = makeContext()
        ctx.selectionMode = [.face]
        let a = ctx.display(try makeBox())
        let b = ctx.display(try makeBox())
        ctx.select(.face(a, faceIndex: 0))
        ctx.select(.face(b, faceIndex: 0))
        #expect(overlayBodies(ctx).count == 2)
    }

    @Test func t_overlayVerticesPushedAlongNormal() throws {
        let ctx = makeContext()
        ctx.selectionMode = [.face]
        let obj = ctx.display(try makeBox())
        ctx.select(.face(obj, faceIndex: 0))

        let source = try #require(ctx.bodies.first { !$0.id.hasPrefix("ais.overlay.") })
        let overlay = try #require(overlayBodies(ctx).first)

        // The overlay's first vertex should differ from any source vertex by a positive
        // displacement along its stored normal — verifies the cheap-route z-fight push.
        let stride = 6
        let oPos = SIMD3<Float>(overlay.vertexData[0], overlay.vertexData[1], overlay.vertexData[2])
        let oNor = SIMD3<Float>(overlay.vertexData[3], overlay.vertexData[4], overlay.vertexData[5])

        // Find the matching source vertex (same normal, same un-pushed position).
        var matched = false
        let sourceVertCount = source.vertexData.count / stride
        for i in 0..<sourceVertCount {
            let base = i * stride
            let sNor = SIMD3<Float>(source.vertexData[base + 3], source.vertexData[base + 4], source.vertexData[base + 5])
            guard simd_distance(sNor, oNor) < 1e-4 else { continue }
            let sPos = SIMD3<Float>(source.vertexData[base], source.vertexData[base + 1], source.vertexData[base + 2])
            let delta = oPos - sPos
            let alongNormal = simd_dot(delta, oNor)
            if alongNormal > 1e-5 && simd_length(delta - oNor * alongNormal) < 1e-4 {
                matched = true
                break
            }
        }
        #expect(matched, "Overlay vertex must be the source vertex pushed along its normal")
    }

    // MARK: - Body overlays via viewport.selectedBodyIDs

    @Test func t_bodySelection_pushesIDToViewport() throws {
        let ctx = makeContext()
        ctx.selectionMode = [.body]
        let obj = ctx.display(try makeBox())
        ctx.select(.body(obj))
        let entryBodyID = try #require(ctx.bodies.first?.id)
        #expect(ctx.viewport.selectedBodyIDs == [entryBodyID])
    }

    @Test func t_clearSelection_clearsViewportBodyIDs() throws {
        let ctx = makeContext()
        ctx.selectionMode = [.body]
        let obj = ctx.display(try makeBox())
        ctx.select(.body(obj))
        ctx.clearSelection()
        #expect(ctx.viewport.selectedBodyIDs.isEmpty)
    }

    @Test func t_bodySelection_doesNotProduceFaceOverlay() throws {
        let ctx = makeContext()
        ctx.selectionMode = [.body]
        let obj = ctx.display(try makeBox())
        ctx.select(.body(obj))
        #expect(overlayBodies(ctx).isEmpty)
    }

    // MARK: - Lifecycle

    @Test func t_remove_dropsOverlayForRemovedBody() throws {
        let ctx = makeContext()
        ctx.selectionMode = [.face]
        let obj = ctx.display(try makeBox())
        ctx.select(.face(obj, faceIndex: 0))
        #expect(overlayBodies(ctx).count == 1)

        ctx.remove(obj)
        #expect(overlayBodies(ctx).isEmpty)
        #expect(ctx.bodies.isEmpty)
    }

    @Test func t_displayAfterSelection_keepsOverlayAtEndOfBodies() throws {
        let ctx = makeContext()
        ctx.selectionMode = [.face]
        let a = ctx.display(try makeBox())
        ctx.select(.face(a, faceIndex: 0))
        _ = ctx.display(try makeBox())

        let lastID = try #require(ctx.bodies.last?.id)
        #expect(lastID.hasPrefix("ais.overlay.sel."))
    }
}
