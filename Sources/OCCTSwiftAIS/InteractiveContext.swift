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

    /// Body IDs of the overlay bodies currently injected into `bodies`.
    /// Tracked so we can replace them in-place on each selection update.
    private var overlayBodyIDs: Set<String> = []

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
            bodies.append(body)
        }

        entriesByID[object.id] = Entry(
            object: object, bodyID: bodyID, metadata: metadata, style: style
        )
        entriesByBodyID[bodyID] = object.id

        // Keep overlays trailing so newly-displayed bodies don't render in front of them.
        if !overlayBodyIDs.isEmpty {
            updateSelectionVisuals()
        }
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

    // MARK: - Highlight overlay (cheap route — sub-mesh + normal offset)

    private func updateSelectionVisuals() {
        // Body-level selection → renderer's built-in body highlight set.
        let selectedBodyIDs: Set<String> = Set(
            selection.subshapes.compactMap { sub -> String? in
                guard case .body(let obj) = sub else { return nil }
                return entriesByID[obj.id]?.bodyID
            }
        )
        viewport.selectedBodyIDs = selectedBodyIDs

        // Face-level selection → overlay sub-mesh per source body.
        var facesByObjectID: [UUID: Set<Int>] = [:]
        for sub in selection.subshapes {
            guard case .face(let obj, let idx) = sub else { continue }
            facesByObjectID[obj.id, default: []].insert(idx)
        }

        // Drop existing overlays before rebuilding.
        if !overlayBodyIDs.isEmpty {
            bodies.removeAll { overlayBodyIDs.contains($0.id) }
            overlayBodyIDs.removeAll()
        }

        let highlightRGBA = SIMD4<Float>(highlightStyle.selectionColor, 1.0)
        for (objectID, faceIndices) in facesByObjectID {
            guard let entry = entriesByID[objectID],
                  let metadata = entry.metadata,
                  let sourceBody = bodies.first(where: { $0.id == entry.bodyID }) else { continue }
            let overlayID = "ais.overlay.sel.\(objectID.uuidString)"
            if let overlay = Self.makeFaceOverlay(
                sourceBody: sourceBody,
                metadata: metadata,
                faceIndices: faceIndices,
                overlayID: overlayID,
                color: highlightRGBA
            ) {
                bodies.append(overlay)
                overlayBodyIDs.insert(overlayID)
            }
        }
    }

    /// Builds a sub-mesh from the source body containing only the triangles whose
    /// `faceIndex` is in `faceIndices`. Vertices are pushed along their normal by a
    /// bbox-relative epsilon so the overlay wins the depth test against the source.
    private static func makeFaceOverlay(
        sourceBody: ViewportBody,
        metadata: CADBodyMetadata,
        faceIndices: Set<Int>,
        overlayID: String,
        color: SIMD4<Float>
    ) -> ViewportBody? {
        let stride = 6
        let triangleCount = sourceBody.indices.count / 3
        guard triangleCount > 0,
              metadata.faceIndices.count == triangleCount else { return nil }

        let epsilon = computeOverlayEpsilon(vertexData: sourceBody.vertexData, stride: stride)

        var newVertexData: [Float] = []
        var newIndices: [UInt32] = []
        var newFaceIndices: [Int32] = []
        var localIndex: [UInt32: UInt32] = [:]

        for triIdx in 0..<triangleCount {
            let faceIdx = Int(metadata.faceIndices[triIdx])
            guard faceIndices.contains(faceIdx) else { continue }

            for k in 0..<3 {
                let srcIdx = sourceBody.indices[triIdx * 3 + k]
                let local: UInt32
                if let existing = localIndex[srcIdx] {
                    local = existing
                } else {
                    local = UInt32(newVertexData.count / stride)
                    let base = Int(srcIdx) * stride
                    let nx = sourceBody.vertexData[base + 3]
                    let ny = sourceBody.vertexData[base + 4]
                    let nz = sourceBody.vertexData[base + 5]
                    newVertexData.append(contentsOf: [
                        sourceBody.vertexData[base]     + nx * epsilon,
                        sourceBody.vertexData[base + 1] + ny * epsilon,
                        sourceBody.vertexData[base + 2] + nz * epsilon,
                        nx, ny, nz
                    ])
                    localIndex[srcIdx] = local
                }
                newIndices.append(local)
            }
            newFaceIndices.append(metadata.faceIndices[triIdx])
        }

        guard !newIndices.isEmpty else { return nil }

        return ViewportBody(
            id: overlayID,
            vertexData: newVertexData,
            indices: newIndices,
            edges: [],
            faceIndices: newFaceIndices,
            color: color
        )
    }

    private static func computeOverlayEpsilon(vertexData: [Float], stride: Int) -> Float {
        guard vertexData.count >= stride else { return 1e-3 }
        var minP = SIMD3<Float>(repeating:  .infinity)
        var maxP = SIMD3<Float>(repeating: -.infinity)
        var i = 0
        while i + 2 < vertexData.count {
            let p = SIMD3<Float>(vertexData[i], vertexData[i + 1], vertexData[i + 2])
            minP = simd_min(minP, p)
            maxP = simd_max(maxP, p)
            i += stride
        }
        let diag = simd_distance(minP, maxP)
        return max(diag * 0.0005, 1e-5)
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
}
