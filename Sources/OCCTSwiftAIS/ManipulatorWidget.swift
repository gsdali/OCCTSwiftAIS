import Foundation
import simd
import OCCTSwift
import OCCTSwiftViewport

/// Three-axis manipulator gizmo for translating (`v0.2`), rotating (`v0.3`), or
/// scaling a target `InteractiveObject`.
///
/// ## Wiring
///
/// 1. Build the widget for a target `InteractiveObject`.
/// 2. Call `install(in:)` with the `InteractiveContext` displaying the target —
///    three axis-arrow bodies (`ais.widget.<UUID>.x|y|z`) appear in the scene.
/// 3. From your gesture handler, call `hitTest(ndc:camera:aspect:)` to see which
///    axis (if any) the user grabbed, then `beginDrag` / `updateDrag` / `endDrag`
///    as the pointer moves and releases. NDC is `[-1, 1]` with +Y up.
/// 4. Observe `transform`, `onChange`, `onCommit` to react.
///
/// Widget bodies are tagged so they don't enter user pick events — the
/// `InteractiveContext`'s pick handler ignores any body that wasn't displayed
/// through `display(_:)`.
///
/// ## Limitations (v0.2)
///
/// - The widget reports a `transform` via callbacks; **it does not visually
///   move the target body**. The renderer doesn't yet expose a per-body
///   transform; live visual updates require renderer-side support (see SPEC.md
///   §"Coordinations needed"). Apply the transform yourself on `onCommit`,
///   typically by re-displaying the target with a transformed `Shape`.
/// - The widget arrows themselves *do* follow the running transform during
///   drag, so the user sees their input reflected on the gizmo.
/// - `mode = .rotate` and `.scale` are not yet implemented; constructing with
///   either is allowed but `install(in:)` only renders translate handles.
@MainActor
public final class ManipulatorWidget: ObservableObject {

    public enum Mode: Sendable {
        case translate
        case rotate
        case scale
    }

    public enum Axis: Hashable, Sendable, CaseIterable {
        case x, y, z

        public var direction: SIMD3<Float> {
            switch self {
            case .x: return SIMD3<Float>(1, 0, 0)
            case .y: return SIMD3<Float>(0, 1, 0)
            case .z: return SIMD3<Float>(0, 0, 1)
            }
        }

        public var color: SIMD4<Float> {
            switch self {
            case .x: return SIMD4<Float>(1.00, 0.25, 0.25, 1.0)
            case .y: return SIMD4<Float>(0.25, 0.90, 0.25, 1.0)
            case .z: return SIMD4<Float>(0.30, 0.45, 1.00, 1.0)
            }
        }

        fileprivate var suffix: String {
            switch self {
            case .x: return "x"
            case .y: return "y"
            case .z: return "z"
            }
        }
    }

    // MARK: - Inputs

    public let target: InteractiveObject
    public let mode: Mode

    /// Length of each axis arrow in world units. Pick a value relative to your
    /// target's bounding box. Defaults to `1.0`.
    public var size: Float = 1.0

    /// Arrow shaft radius in world units.
    public var shaftRadius: Float = 0.025

    /// Hit-test threshold in NDC units (≈ fraction of viewport width).
    /// A click within this perpendicular distance of an arrow's projected
    /// centerline is considered a hit. Default `0.04` (~ 4% of viewport).
    public var hitNDCTolerance: Float = 0.04

    public var snapTranslate: Float?
    public var snapRotateDeg: Float?

    public var onChange: ((simd_float4x4) -> Void)?
    public var onCommit: ((simd_float4x4) -> Void)?

    // MARK: - Observable

    @Published public private(set) var transform: simd_float4x4 = matrix_identity_float4x4
    @Published public private(set) var isInstalled: Bool = false
    @Published public private(set) var activeAxis: Axis? = nil

    public var isDragging: Bool { activeAxis != nil }

    // MARK: - Internal state

    private weak var context: InteractiveContext?
    private var pivot: SIMD3<Float> = .zero

    private struct DragState {
        let axis: Axis
        let initialAxisParam: Float
        let initialTransform: simd_float4x4
    }
    private var dragState: DragState?

    // MARK: - Init

    public init(target: InteractiveObject, mode: Mode = .translate) {
        self.target = target
        self.mode = mode
    }

    // MARK: - Install

    /// Add the gizmo's axis bodies to `context.bodies` and remember the context
    /// so subsequent transform updates can refresh the gizmo.
    public func install(in context: InteractiveContext) {
        guard !isInstalled else { return }
        self.context = context
        self.pivot = computePivot(in: context) ?? .zero
        rebuildArrowBodies()
        isInstalled = true
    }

    public func uninstall() {
        guard isInstalled, let context else {
            isInstalled = false
            self.context = nil
            return
        }
        let prefix = bodyIDPrefix
        context.removeInternalBodies { $0.hasPrefix(prefix) }
        self.context = nil
        isInstalled = false
        activeAxis = nil
        dragState = nil
    }

    // MARK: - Hit test

    /// Returns the axis under the given NDC point, or `nil` if the click missed
    /// every handle. NDC is `[-1, 1]` with +Y up.
    public func hitTest(ndc: SIMD2<Float>, camera: CameraState, aspect: Float) -> Axis? {
        let viewProj = camera.projectionMatrix(aspectRatio: aspect) * camera.viewMatrix
        let originWS = pivot + currentTranslation()

        var best: (axis: Axis, distance: Float, depth: Float)? = nil
        for axis in Axis.allCases {
            let endWS = originWS + axis.direction * size
            guard let p0 = ProjectionUtility.worldToNDC(point: originWS, vpMatrix: viewProj),
                  let p1 = ProjectionUtility.worldToNDC(point: endWS,    vpMatrix: viewProj) else {
                continue
            }
            let p0xy = SIMD2<Float>(p0.x, p0.y)
            let p1xy = SIMD2<Float>(p1.x, p1.y)
            let dist = pointToSegmentDistance(point: ndc, a: p0xy, b: p1xy)
            guard dist <= hitNDCTolerance else { continue }
            // Pick the closest-to-camera handle on overlap.
            let depth = min(p0.z, p1.z)
            if let current = best {
                if depth < current.depth {
                    best = (axis, dist, depth)
                }
            } else {
                best = (axis, dist, depth)
            }
        }
        return best?.axis
    }

    // MARK: - Drag

    /// Begin a drag of the named axis. Captures the initial axis-line parameter
    /// where the pick ray crosses the axis at NDC `ndc`.
    public func beginDrag(axis: Axis, ndc: SIMD2<Float>, camera: CameraState, aspect: Float) {
        guard mode == .translate else { return }
        let pickRay = Ray.fromCamera(ndc: ndc, cameraState: camera, aspectRatio: aspect)
        let originWS = pivot + currentTranslation()
        guard let initial = closestParam(onAxisLine: originWS, axisDir: axis.direction, ray: pickRay) else {
            return
        }
        dragState = DragState(axis: axis, initialAxisParam: initial, initialTransform: transform)
        activeAxis = axis
    }

    /// Update the running transform from a drag at NDC `ndc`. Fires `onChange`.
    public func updateDrag(ndc: SIMD2<Float>, camera: CameraState, aspect: Float) {
        guard let state = dragState else { return }
        let pickRay = Ray.fromCamera(ndc: ndc, cameraState: camera, aspectRatio: aspect)
        let originWS = pivot + extractTranslation(from: state.initialTransform)
        guard let now = closestParam(onAxisLine: originWS, axisDir: state.axis.direction, ray: pickRay) else {
            return
        }
        var delta = now - state.initialAxisParam
        if let step = snapTranslate, step > 0 {
            delta = (delta / step).rounded() * step
        }
        var newTransform = state.initialTransform
        let translation = state.axis.direction * delta
        newTransform.columns.3.x += translation.x
        newTransform.columns.3.y += translation.y
        newTransform.columns.3.z += translation.z
        transform = newTransform
        rebuildArrowBodies()
        onChange?(transform)
    }

    /// End the active drag. If `commit` is true, fires `onCommit` with the
    /// running transform.
    public func endDrag(commit: Bool = true) {
        guard dragState != nil else { return }
        if commit {
            onCommit?(transform)
        }
        dragState = nil
        activeAxis = nil
    }

    /// Reset the running transform to identity (and refresh the gizmo).
    public func reset() {
        transform = matrix_identity_float4x4
        if isInstalled {
            rebuildArrowBodies()
        }
    }

    // MARK: - Internals

    var bodyIDPrefix: String { "ais.widget.\(target.id.uuidString)." }

    func bodyID(for axis: Axis) -> String { bodyIDPrefix + axis.suffix }

    private func computePivot(in context: InteractiveContext) -> SIMD3<Float>? {
        guard let body = context.sourceBody(for: target) else { return nil }
        return centerOfVertexData(body.vertexData, stride: 6)
    }

    private func rebuildArrowBodies() {
        guard let context else { return }
        let prefix = bodyIDPrefix
        context.removeInternalBodies { $0.hasPrefix(prefix) }
        let origin = pivot + currentTranslation()
        for axis in Axis.allCases {
            let body = ManipulatorGeometry.makeAxisArrow(
                id: bodyID(for: axis),
                origin: origin,
                direction: axis.direction,
                length: size,
                radius: shaftRadius,
                color: axis.color
            )
            context.appendInternalBody(body)
        }
    }

    private func currentTranslation() -> SIMD3<Float> {
        extractTranslation(from: transform)
    }
}

// MARK: - Free helpers

private func extractTranslation(from m: simd_float4x4) -> SIMD3<Float> {
    SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
}

private func centerOfVertexData(_ data: [Float], stride: Int) -> SIMD3<Float>? {
    guard data.count >= stride else { return nil }
    var minP = SIMD3<Float>(repeating:  .infinity)
    var maxP = SIMD3<Float>(repeating: -.infinity)
    var i = 0
    while i + 2 < data.count {
        let p = SIMD3<Float>(data[i], data[i + 1], data[i + 2])
        minP = simd_min(minP, p)
        maxP = simd_max(maxP, p)
        i += stride
    }
    return (minP + maxP) * 0.5
}

/// Perpendicular distance from `point` to the segment between `a` and `b`,
/// clamped to the segment endpoints. All in NDC.
private func pointToSegmentDistance(point: SIMD2<Float>, a: SIMD2<Float>, b: SIMD2<Float>) -> Float {
    let ab = b - a
    let denom = simd_dot(ab, ab)
    if denom < 1e-9 { return simd_distance(point, a) }
    var t = simd_dot(point - a, ab) / denom
    t = max(0, min(1, t))
    let closest = a + ab * t
    return simd_distance(point, closest)
}

/// Parameter `s` such that `axisOrigin + axisDir * s` is the closest point on
/// the axis line to `ray`. Returns `nil` if the lines are nearly parallel.
private func closestParam(
    onAxisLine axisOrigin: SIMD3<Float>,
    axisDir: SIMD3<Float>,
    ray: Ray
) -> Float? {
    let d1 = simd_normalize(ray.direction)
    let d2 = simd_normalize(axisDir)
    let w0 = ray.origin - axisOrigin
    let b = simd_dot(d1, d2)
    let denom = 1.0 - b * b
    if denom < 1e-6 { return nil }                  // parallel — drag undefined
    let d = simd_dot(d1, w0)
    let e = simd_dot(d2, w0)
    return (e - b * d) / denom
}
