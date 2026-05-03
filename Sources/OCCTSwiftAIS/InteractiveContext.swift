import Foundation
import Combine
import simd
import OCCTSwift
import OCCTSwiftViewport
import OCCTSwiftTools

/// Per-scene interactive state. One `InteractiveContext` ↔ one `ViewportController`.
///
/// The context owns the array of `ViewportBody`s rendered by `MetalViewportView`.
/// Bind it via `MetalViewportView(controller: ctx.viewport, bodies: $ctx.bodies)`
/// when `ctx` is a `@StateObject`.
///
/// ## Selection semantics
/// - `select(_:)` / `deselect(_:)` mutate the selection as a `Set` — adding the
///   same sub-shape twice is idempotent.
/// - A pick event from the viewport **replaces** the selection with the picked
///   sub-shape. Empty-space picks (`pickResult == nil`) leave the selection alone.
/// - Changing `selectionMode` clears the current selection.
@MainActor
public final class InteractiveContext: ObservableObject {

    // MARK: - Inputs

    public let viewport: ViewportController

    // MARK: - Scene

    /// Bodies fed to `MetalViewportView`. Bind via `$bodies`.
    @Published public var bodies: [ViewportBody] = []

    // MARK: - Selection

    @Published public var selectionMode: Set<SelectionMode> = [.body] {
        didSet {
            if oldValue != selectionMode { clearSelection() }
        }
    }

    @Published public private(set) var selection: Selection = Selection() {
        didSet {
            if oldValue != selection { updateSelectionVisuals() }
        }
    }
    @Published public private(set) var hover: SubShape? = nil

    // MARK: - Style

    public var highlightStyle: HighlightStyle = .default

    /// Dimensions added via `add(_:)`. Strongly held so the dimension lives
    /// as long as it's displayed; weak refs would let user-discarded
    /// dimensions vanish from the scene.
    var dimensionRegistry: [ObjectIdentifier: any Dimension] = [:]

    // MARK: - Registry

    private struct Entry {
        let object: InteractiveObject
        let bodyID: String
        let metadata: CADBodyMetadata?
        var style: PresentationStyle
    }
    private var entriesByID: [UUID: Entry] = [:]
    private var entriesByBodyID: [String: UUID] = [:]

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    public init(viewport: ViewportController) {
        self.viewport = viewport

        viewport.$pickResult
            .dropFirst()
            .sink { [weak self] result in
                MainActor.assumeIsolated {
                    self?.handlePick(result)
                }
            }
            .store(in: &cancellables)

        viewport.$hoveredBodyID
            .dropFirst()
            .sink { [weak self] bodyID in
                MainActor.assumeIsolated {
                    self?.handleHover(bodyID: bodyID)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Display

    /// Display a shape with topology-aware selection enabled.
    @discardableResult
    public func display(_ shape: Shape, style: PresentationStyle = .default) -> InteractiveObject {
        let object = InteractiveObject(shape: shape)
        let bodyID = "ais.\(object.id.uuidString)"
        let rgba = SIMD4<Float>(style.color, 1.0 - style.transparency)

        let (body, metadata) = CADFileLoader.shapeToBodyAndMetadata(
            shape, id: bodyID, color: rgba
        )

        if var body {
            body.isVisible = style.visible
            // Workaround for OCCTSwiftTools#8 — populate edge / vertex picking
            // arrays here so v0.55.0+ renderer can fire .edge / .vertex picks.
            // Once Tools populates these directly the workaround can drop.
            populateEdgeVertexPickArrays(body: &body, shape: shape, metadata: metadata)
            bodies.append(body)
        }

        entriesByID[object.id] = Entry(
            object: object, bodyID: bodyID, metadata: metadata, style: style
        )
        entriesByBodyID[bodyID] = object.id
        return object
    }

    public func remove(_ object: InteractiveObject) {
        guard let entry = entriesByID.removeValue(forKey: object.id) else { return }
        entriesByBodyID.removeValue(forKey: entry.bodyID)
        bodies.removeAll { $0.id == entry.bodyID }

        let dropped = selection.subshapes.filter { $0.object.id == object.id }
        if !dropped.isEmpty {
            selection = Selection(selection.subshapes.subtracting(dropped))
        }
        if let h = hover, h.object.id == object.id {
            hover = nil
        }
    }

    public func removeAll() {
        bodies.removeAll()
        entriesByID.removeAll()
        entriesByBodyID.removeAll()
        selection = Selection()
        hover = nil
        dimensionRegistry.removeAll()
        viewport.measurements.removeAll()
    }

    // MARK: - Selection mutation

    /// Add a sub-shape to the current selection. Idempotent.
    public func select(_ subshape: SubShape) {
        var s = selection.subshapes
        s.insert(subshape)
        selection = Selection(s)
    }

    public func deselect(_ subshape: SubShape) {
        var s = selection.subshapes
        s.remove(subshape)
        selection = Selection(s)
    }

    public func clearSelection() {
        selection = Selection()
    }

    // MARK: - Style

    public func setStyle(_ style: PresentationStyle, for object: InteractiveObject) {
        guard var entry = entriesByID[object.id] else { return }
        entry.style = style
        entriesByID[object.id] = entry

        if let i = bodies.firstIndex(where: { $0.id == entry.bodyID }) {
            bodies[i].color = SIMD4<Float>(style.color, 1.0 - style.transparency)
            bodies[i].isVisible = style.visible
        }
    }

    public func setHighlightStyle(_ style: HighlightStyle) {
        self.highlightStyle = style
        updateSelectionVisuals()
    }

    // MARK: - Internal accessors (used by ManipulatorWidget)

    /// The body ID currently associated with `object`, or nil if not displayed.
    func bodyID(for object: InteractiveObject) -> String? {
        entriesByID[object.id]?.bodyID
    }

    /// The source `ViewportBody` for `object`, or nil if the object is not displayed
    /// or its tessellation produced no mesh.
    func sourceBody(for object: InteractiveObject) -> ViewportBody? {
        guard let id = entriesByID[object.id]?.bodyID else { return nil }
        return bodies.first { $0.id == id }
    }

    /// Append a body created by an internal subsystem (manipulator, dimension, …).
    /// The body is **not** registered as a selectable `InteractiveObject` and is
    /// invisible to selection / hover wiring.
    func appendInternalBody(_ body: ViewportBody) {
        bodies.append(body)
    }

    /// Remove every body whose id satisfies `predicate`.
    func removeInternalBodies(where predicate: (String) -> Bool) {
        bodies.removeAll { predicate($0.id) }
    }

    // MARK: - Highlight overlay (renderer-backed, OCCTSwiftViewport ≥ 0.55.1)

    /// Body-level selection → `viewport.selectedBodyIDs`. Face-level selection
    /// → per-triangle styles on the source body's `triangleStyles`. No overlay
    /// bodies, no normal-offset push.
    private func updateSelectionVisuals() {
        let selectedBodyIDs: Set<String> = Set(
            selection.subshapes.compactMap { sub -> String? in
                guard case .body(let obj) = sub else { return nil }
                return entriesByID[obj.id]?.bodyID
            }
        )
        viewport.selectedBodyIDs = selectedBodyIDs

        var facesByObjectID: [UUID: Set<Int>] = [:]
        for sub in selection.subshapes {
            guard case .face(let obj, let idx) = sub else { continue }
            facesByObjectID[obj.id, default: []].insert(idx)
        }

        let highlightRGBA = SIMD4<Float>(highlightStyle.selectionColor, 1.0)

        for (objectID, entry) in entriesByID {
            guard let bodyIdx = bodies.firstIndex(where: { $0.id == entry.bodyID }) else {
                continue
            }
            let triangleCount = bodies[bodyIdx].indices.count / 3
            guard triangleCount > 0, let metadata = entry.metadata,
                  metadata.faceIndices.count == triangleCount else {
                if !bodies[bodyIdx].triangleStyles.isEmpty {
                    bodies[bodyIdx].triangleStyles = []
                }
                continue
            }
            let selectedFaces = facesByObjectID[objectID] ?? []
            if selectedFaces.isEmpty {
                if !bodies[bodyIdx].triangleStyles.isEmpty {
                    bodies[bodyIdx].triangleStyles = []
                }
            } else {
                let highlight = TriangleStyle(color: highlightRGBA)
                var styles = Array(repeating: TriangleStyle.none, count: triangleCount)
                for triIdx in 0..<triangleCount {
                    let faceIdx = Int(metadata.faceIndices[triIdx])
                    if selectedFaces.contains(faceIdx) {
                        styles[triIdx] = highlight
                    }
                }
                bodies[bodyIdx].triangleStyles = styles
            }
        }
    }

    // MARK: - Pick / hover wiring

    /// Internal entry point — also called from tests with a synthesised `PickResult`.
    func handlePick(_ result: PickResult?) {
        guard let result,
              let id = entriesByBodyID[result.bodyID],
              let entry = entriesByID[id] else { return }

        if let sub = resolveSubShape(from: result, entry: entry) {
            selection = Selection([sub])
        }
    }

    func handleHover(bodyID: String?) {
        guard let bodyID,
              let id = entriesByBodyID[bodyID],
              let entry = entriesByID[id] else {
            hover = nil
            return
        }
        // Renderer publishes hover at body granularity; face/edge hover requires
        // a per-triangle hover stream that doesn't exist yet.
        hover = selectionMode.contains(.body) ? .body(entry.object) : nil
    }

    private func resolveSubShape(from result: PickResult, entry: Entry) -> SubShape? {
        switch result.kind {
        case .face:
            return resolveFaceSubShape(from: result, entry: entry)
        case .edge:
            return resolveEdgeSubShape(from: result, entry: entry)
        case .vertex:
            return resolveVertexSubShape(from: result, entry: entry)
        }
    }

    private func resolveFaceSubShape(from result: PickResult, entry: Entry) -> SubShape? {
        if selectionMode.contains(.face),
           let metadata = entry.metadata,
           result.triangleIndex >= 0,
           result.triangleIndex < metadata.faceIndices.count {
            let faceIdx = Int(metadata.faceIndices[result.triangleIndex])
            if faceIdx >= 0 {
                return .face(entry.object, faceIndex: faceIdx)
            }
        }
        if selectionMode.contains(.body) {
            return .body(entry.object)
        }
        return nil
    }

    private func resolveEdgeSubShape(from result: PickResult, entry: Entry) -> SubShape? {
        guard selectionMode.contains(.edge) else { return nil }
        guard let body = bodies.first(where: { $0.id == entry.bodyID }) else { return nil }
        guard result.triangleIndex >= 0,
              result.triangleIndex < body.edgeIndices.count else { return nil }
        let edgeIdx = Int(body.edgeIndices[result.triangleIndex])
        guard edgeIdx >= 0 else { return nil }
        return .edge(entry.object, edgeIndex: edgeIdx)
    }

    private func resolveVertexSubShape(from result: PickResult, entry: Entry) -> SubShape? {
        guard selectionMode.contains(.vertex) else { return nil }
        guard let body = bodies.first(where: { $0.id == entry.bodyID }) else { return nil }
        guard result.triangleIndex >= 0,
              result.triangleIndex < body.vertexIndices.count else { return nil }
        let vIdx = Int(body.vertexIndices[result.triangleIndex])
        guard vIdx >= 0 else { return nil }
        return .vertex(entry.object, vertexIndex: vIdx)
    }

    /// Populate `body.edgeIndices` / `body.vertices` / `body.vertexIndices`
    /// so the renderer's edge / vertex pick pipelines fire **and** so the
    /// pick primitive index round-trips to a `TopoDS_Vertex` on the source
    /// shape via `Selection.vertices`.
    ///
    /// `OCCTSwiftTools` v0.4.1 also populates `edgeIndices` and `vertices`
    /// during `shapeToBodyAndMetadata`, but its `vertices` are the
    /// deduplicated polyline endpoints (not the source TopoDS vertices)
    /// and it leaves `vertexIndices` empty — which would make a vertex
    /// pick's `primitiveIndex` an opaque position into the polyline-endpoint
    /// list, not a source-vertex index. AIS overrides Tools' `vertices` /
    /// `vertexIndices` with `shape.vertices()` so picks land on real
    /// `TopoDS_Vertex` sub-shapes. `edgeIndices` we accept from Tools when
    /// they're already populated; otherwise we flatten metadata ourselves.
    private func populateEdgeVertexPickArrays(
        body: inout ViewportBody,
        shape: Shape,
        metadata: CADBodyMetadata?
    ) {
        if body.edgeIndices.isEmpty, let metadata {
            var flat: [Int32] = []
            flat.reserveCapacity(metadata.edgePolylines.reduce(0) { $0 + max($1.points.count - 1, 0) })
            for poly in metadata.edgePolylines {
                let segs = max(poly.points.count - 1, 0)
                if segs > 0 {
                    flat.append(contentsOf: Array(repeating: Int32(poly.edgeIndex), count: segs))
                }
            }
            body.edgeIndices = flat
        }
        let sourceVerts = shape.vertices()
        body.vertices = sourceVerts.map { SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z)) }
        body.vertexIndices = (0..<sourceVerts.count).map { Int32($0) }
    }
}
