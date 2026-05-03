import Foundation
import simd
import OCCTSwift
import OCCTSwiftViewport

/// A dimension annotation — a measurement displayed in the scene as leader
/// lines plus a billboarded label. Concrete subclasses: `LinearDimension`
/// (v0.4); `AngularDimension` and `RadialDimension` come in v0.5.
///
/// Dimensions render via the `MeasurementOverlay` SwiftUI Canvas overlay
/// inside `MetalViewportView`. AIS owns the topology-aware anchor resolution
/// (sub-shape → world point) and pushes the resulting `ViewportMeasurement`
/// through `InteractiveContext.add(_:)`.
public protocol Dimension: AnyObject, Sendable {
    /// Stable id used to track the dimension across `add` / `remove` cycles.
    var id: String { get }

    /// Human-readable label (e.g. `"5.32"`). Customise the label by passing
    /// `customLabel` to the dimension's initialiser.
    var label: String { get }

    /// World-space anchor points, in the order each concrete dimension type
    /// expects (e.g. `[start, end]` for `LinearDimension`).
    var anchorPoints: [SIMD3<Float>] { get }

    /// `ViewportMeasurement` form for handoff to the renderer's overlay.
    var viewportMeasurement: ViewportMeasurement { get }
}

// MARK: - LinearDimension

public final class LinearDimension: Dimension, @unchecked Sendable {

    public let id: String
    public let from: SubShape
    public let to: SubShape

    /// If non-nil, both anchors are orthogonally projected onto this plane
    /// before the distance is measured — the dimension reports the **in-plane**
    /// length rather than the straight 3D distance.
    public let plane: WorkPlane?

    /// Optional caller-supplied label; if nil the formatted distance is used.
    public var customLabel: String?

    public init(
        from: SubShape,
        to: SubShape,
        plane: WorkPlane? = nil,
        customLabel: String? = nil,
        id: String? = nil
    ) {
        self.id = id ?? "ais.dimension.linear.\(UUID().uuidString)"
        self.from = from
        self.to = to
        self.plane = plane
        self.customLabel = customLabel
    }

    public var anchorPoints: [SIMD3<Float>] {
        let a = DimensionAnchor.resolve(from)
        let b = DimensionAnchor.resolve(to)
        if let plane {
            return [DimensionAnchor.project(a, onto: plane), DimensionAnchor.project(b, onto: plane)]
        }
        return [a, b]
    }

    /// Straight-line distance between the two anchors (after optional plane
    /// projection). `nan` if either anchor failed to resolve.
    public var distance: Float {
        let pts = anchorPoints
        guard pts.count == 2 else { return .nan }
        return simd_distance(pts[0], pts[1])
    }

    public var label: String {
        if let customLabel { return customLabel }
        return DimensionAnchor.formatDistance(distance)
    }

    public var viewportMeasurement: ViewportMeasurement {
        let pts = anchorPoints
        let start = pts.indices.contains(0) ? pts[0] : .zero
        let end   = pts.indices.contains(1) ? pts[1] : .zero
        return .distance(DistanceMeasurement(id: id, start: start, end: end, label: customLabel))
    }
}

// MARK: - Anchor resolution

/// Maps a `SubShape` to a world-space anchor point. Used by dimension types.
enum DimensionAnchor {

    static func resolve(_ subshape: SubShape) -> SIMD3<Float> {
        switch subshape {
        case .body(let obj):
            return resolveBody(obj)
        case .face(let obj, let idx):
            return resolveFace(obj, faceIndex: idx)
        case .edge(let obj, let idx):
            return resolveEdge(obj, edgeIndex: idx)
        case .vertex(let obj, let idx):
            return resolveVertex(obj, vertexIndex: idx)
        }
    }

    private static func resolveBody(_ obj: InteractiveObject) -> SIMD3<Float> {
        // Bbox center of the source shape.
        let (lo, hi) = obj.shape.bounds
        let center = (lo + hi) * 0.5
        return SIMD3<Float>(Float(center.x), Float(center.y), Float(center.z))
    }

    private static func resolveFace(_ obj: InteractiveObject, faceIndex: Int) -> SIMD3<Float> {
        // Bbox center of the face — cheap, robust for axis-aligned faces.
        // Curved faces would be better served by the area-weighted centroid
        // (OCCTSwiftTools.ShapeMeasurements.faceCentroids) but that's an
        // O(faces) computation; bbox center is constant time per face.
        guard let faceShape = obj.shape.subShape(type: .face, index: faceIndex),
              let face = OCCTSwift.Face(faceShape) else {
            return .zero
        }
        let (lo, hi) = face.bounds
        let center = (lo + hi) * 0.5
        return SIMD3<Float>(Float(center.x), Float(center.y), Float(center.z))
    }

    private static func resolveEdge(_ obj: InteractiveObject, edgeIndex: Int) -> SIMD3<Float> {
        guard let edge = obj.shape.edge(at: edgeIndex) else { return .zero }
        let ends = edge.endpoints
        let mid = (ends.start + ends.end) * 0.5
        return SIMD3<Float>(Float(mid.x), Float(mid.y), Float(mid.z))
    }

    private static func resolveVertex(_ obj: InteractiveObject, vertexIndex: Int) -> SIMD3<Float> {
        guard let p = obj.shape.vertex(at: vertexIndex) else { return .zero }
        return SIMD3<Float>(Float(p.x), Float(p.y), Float(p.z))
    }

    /// Project `point` orthogonally onto `plane` (signed perpendicular drop).
    static func project(_ point: SIMD3<Float>, onto plane: WorkPlane) -> SIMD3<Float> {
        let n = simd_normalize(plane.normal)
        let signed = simd_dot(point - plane.origin, n)
        return point - n * signed
    }

    static func formatDistance(_ value: Float) -> String {
        if !value.isFinite { return "?" }
        if value >= 100 {
            return String(format: "%.0f", value)
        } else if value >= 10 {
            return String(format: "%.1f", value)
        } else {
            return String(format: "%.2f", value)
        }
    }
}

// MARK: - InteractiveContext glue

extension InteractiveContext {

    /// Add a dimension to the scene. The dimension's `viewportMeasurement` is
    /// pushed to `viewport.measurements`, where the renderer's overlay picks
    /// it up automatically. Idempotent for the same instance.
    @discardableResult
    public func add<D: Dimension>(_ dimension: D) -> D {
        let oid = ObjectIdentifier(dimension)
        if dimensionRegistry[oid] != nil {
            // Already added — refresh the measurement in case anchors changed.
            refreshDimensionMeasurement(dimension)
            return dimension
        }
        dimensionRegistry[oid] = dimension
        viewport.measurements.append(dimension.viewportMeasurement)
        return dimension
    }

    /// Remove a previously-added dimension.
    public func remove(_ dimension: any Dimension) {
        let oid = ObjectIdentifier(dimension)
        guard dimensionRegistry.removeValue(forKey: oid) != nil else { return }
        let id = dimension.id
        viewport.measurements.removeAll { $0.id == id }
    }

    /// All dimensions currently displayed in this context.
    public var dimensions: [any Dimension] {
        Array(dimensionRegistry.values)
    }

    /// Re-fetch a dimension's `viewportMeasurement` and replace it in place
    /// in `viewport.measurements`. Call this if the underlying anchors moved
    /// (e.g. a target shape mutated) — for a static scene you don't need it.
    public func refreshDimensionMeasurement(_ dimension: any Dimension) {
        let id = dimension.id
        if let i = viewport.measurements.firstIndex(where: { $0.id == id }) {
            viewport.measurements[i] = dimension.viewportMeasurement
        }
    }
}
