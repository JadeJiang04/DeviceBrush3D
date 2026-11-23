import ARKit
import SceneKit
import SwiftUI
import UIKit
import AVFoundation
import simd

struct ARCameraView: UIViewControllerRepresentable {
    let model: MeasurementModel
    func makeUIViewController(context: Context) -> ARMeasurementController {
        let controller = ARMeasurementController(model: model)
        model.controller = controller
        return controller
    }
    func updateUIViewController(_ controller: ARMeasurementController, context: Context) {}
    static func dismantleUIViewController(_ controller: ARMeasurementController, coordinator: ()) {
        controller.pause()
    }
}

private struct PendingLine {
    let start: UUID
    let mode: CaptureMode
    let tip: TipOffset
    let constraint: LineConstraint
    let trackingEpoch: Int
}

private struct DrawingSnapshot {
    let document: DrawingDocument
    let pending: PendingLine?
}

private struct Candidate {
    let position: SIMD3<Float>
    let source: String
}

final class ARMeasurementController: UIViewController, ARSessionDelegate, ARCoachingOverlayViewDelegate {
    private let model: MeasurementModel
    private let arView = ARSCNView(frame: .zero)
    private let coaching = ARCoachingOverlayView()
    private var configuration: ARWorldTrackingConfiguration?
    private var running = false
    private var lastUIUpdate: TimeInterval = 0
    private var document = DrawingDocument()
    private var pending: PendingLine?
    private var history: [DrawingSnapshot] = []
    private var trackingEpoch = 0
    private var sessionID = UUID()
    private var baseAnchor: ARAnchor?
    private var baseTransform = matrix_identity_float4x4
    private let originLabelID = UUID()

    // One rigid AR anchor keeps exact manual lengths and shared joints intact
    // when ARKit refines its map. Stored coordinates are Z-up meters.
    private let world = SCNNode()
    private var dots: [UUID: SCNNode] = [:]
    private var lines: [UUID: SCNNode] = [:]
    private var faceNodes: [UUID: SCNNode] = [:]
    private var pathNodes: [UUID: SCNNode] = [:]
    private var livePath: DrawingPath?
    private var sampler = StrokeSampler()
    private var strokeOrigin = SIMD3<Float>.zero
    private var strokeConstraint: LineConstraint = .free
    private let tipLabelID = UUID()
    private let preview = ARMeasurementController.lineNode(color: .systemYellow)
    private var originInView = false
    private var pendingTrackingLost: Bool {
        pending.map { $0.trackingEpoch != trackingEpoch } ?? false
    }
    private var baseX: SIMD3<Float> {
        let c = baseTransform.columns.0
        let flat = SIMD3<Float>(c.x, 0, c.z)
        return simd_length(flat) > 0.01 ? simd_normalize(flat) : SIMD3(1, 0, 0)
    }
    private var baseY: SIMD3<Float> { simd_cross(SIMD3(0, 1, 0), baseX) }
    private func worldPosition(_ p: SIMD3<Float>) -> SIMD3<Float> {
        baseTransform.columns.3.xyz + baseX * p.x + baseY * p.y + SIMD3(0, p.z, 0)
    }
    private func basePosition(_ p: SIMD3<Float>) -> SIMD3<Float> {
        let d = p - baseTransform.columns.3.xyz
        return SIMD3(simd_dot(d, baseX), simd_dot(d, baseY), d.y)
    }
    private func ensureBase(at p: SIMD3<Float>) {
        guard baseAnchor == nil else { return }
        baseTransform = matrix_identity_float4x4
        baseTransform.columns.3 = SIMD4(p.x, p.y, p.z, 1)
        let anchor = ARAnchor(name: "SpatialPenDrawing", transform: baseTransform)
        baseAnchor = anchor
        arView.session.add(anchor: anchor)
    }

    init(model: MeasurementModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("Use init(model:)") }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if HardwareProfile.supported, !UserDefaults.standard.bool(forKey: "extendedTip.v3"), currentUpperLeftCorner != nil {
            model.selectCurrentCorner()
            UserDefaults.standard.set(true, forKey: "extendedTip.v3")
        }
    }

    var currentUpperLeftCorner: DeviceCorner? {
        guard let orientation = view.window?.windowScene?.interfaceOrientation else { return nil }
        return DeviceCorner.upperLeft(in: orientation)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view = arView
        arView.session.delegate = self
        arView.session.delegateQueue = .main
        arView.scene = SCNScene()
        arView.preferredFramesPerSecond = 30
        arView.antialiasingMode = .none
        arView.automaticallyUpdatesLighting = false
        arView.scene.rootNode.addChildNode(world)
        world.addChildNode(preview)
        preview.isHidden = true

        coaching.session = arView.session
        coaching.delegate = self
        coaching.goal = .tracking // Device-pen mode does NOT wait for planes.
        coaching.activatesAutomatically = true
        coaching.frame = arView.bounds
        coaching.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        arView.addSubview(coaching)
        resume()
    }

    func resume() {
        guard isViewLoaded, !running else { return }
        guard ARWorldTrackingConfiguration.isSupported else {
            model.trackingText = "此设备不支持 ARKit 世界跟踪"
            model.hint = "请在真实 iPad 或 iPhone 上运行。"
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            model.cameraDenied = false
            runSession(reset: configuration == nil)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
                DispatchQueue.main.async { self?.resume() }
            }
        default:
            model.cameraDenied = true
            model.trackingText = "需要相机权限"
            model.hint = "允许相机后，返回这里即可开始。"
        }
    }

    private func runSession(reset: Bool) {
        let config = configuration ?? ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        config.planeDetection = [.horizontal, .vertical]
        config.environmentTexturing = .none
        // Playground live views have a 450 MB process limit on the tested iPad.
        // Two endpoints need world tracking, not a full reconstructed mesh.
        config.sceneReconstruction = []
        model.lidarAvailable = false
        if let format = ARWorldTrackingConfiguration.supportedVideoFormats
            .filter({ $0.framesPerSecond == 30 })
            .min(by: { $0.imageResolution.width * $0.imageResolution.height <
                       $1.imageResolution.width * $1.imageResolution.height }) {
            config.videoFormat = format
        }
        configuration = config
        model.isInterrupted = false
        arView.session.run(config, options: reset ? [.resetTracking, .removeExistingAnchors] : [])
        running = true
    }

    func pause() {
        endStroke()
        guard running else { return }
        arView.session.pause()
        running = false
        markTrackingUnavailable("已暂停", hint: "回到应用后重新识别之前看过的场景。")
    }

    func restart() {
        endStroke()
        if let anchor = baseAnchor { arView.session.remove(anchor: anchor) }
        baseAnchor = nil
        baseTransform = matrix_identity_float4x4
        document = DrawingDocument()
        pending = nil
        history.removeAll()
        trackingEpoch += 1
        sessionID = UUID()
        model.labels = []
        model.liveLengthCM = nil
        model.relativeCM = nil
        model.canCapture = false
        model.isTracking = false
        model.editMessage = nil
        syncDocument()
        configuration = nil
        arView.session.pause()
        running = false
        resume()
    }

    private func candidate(in frame: ARFrame) -> Candidate? {
        guard running, !model.isInterrupted, !model.settingsPresented, !model.editorPresented,
              case .normal = frame.camera.trackingState,
              CACurrentMediaTime() - frame.timestamp < 0.4,
              arView.bounds.width > 0, arView.bounds.height > 0 else { return nil }

        if model.mode == .device {
            let local = model.tip.meters
            guard local.x.isFinite, local.y.isFinite, local.z.isFinite,
                  simd_length(local) <= 1.74 else { return nil }
            let p = frame.camera.transform * SIMD4(local.x, local.y, local.z, 1)
            return Candidate(position: p.xyz, source: model.tipDescription)
        }

        let center = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        // Prefer bounded detected surfaces; estimated planes also allow
        // ARKit's mesh-assisted raycasts without waiting for a large plane.
        let targets: [ARRaycastQuery.Target] = [.existingPlaneGeometry, .estimatedPlane]
        for target in targets {
            guard let query = arView.raycastQuery(from: center, allowing: target, alignment: .any),
                  let result = arView.session.raycast(query).first else { continue }
            let position = result.worldTransform.columns.3.xyz
            let distance = simd_distance(position, frame.camera.transform.columns.3.xyz)
            if distance >= 0.05 && distance <= 8 {
                let source = target == .existingPlaneGeometry ? "准星已命中已识别表面" : "准星已命中估计表面"
                return Candidate(position: position, source: source)
            }
        }
        return nil
    }

    private func sampleDetails(_ frame: ARFrame) -> SampleDetails {
        let offset = model.mode == .device && model.tip.enabled
        return SampleDetails(mode: model.mode.rawValue,
                             tipOffsetCameraMeters: offset ? model.tip.meters : .zero,
                             physicalCorner: offset ? model.tip.corner?.rawValue : nil,
                             estimatedTipGeometry: offset && model.tip.corner != nil,
                             frameTime: frame.timestamp)
    }

    func capture(vertexOnly: Bool = false) {
        guard !model.isDrawing else { return }
        guard !pendingTrackingLost, let frame = arView.session.currentFrame,
              let hit = candidate(in: frame) else {
            model.notice = pendingTrackingLost
                ? "本条线段中途丢失了跟踪，请撤销起点后重新取点。"
                : "当前无法取点，请让后置相机看到有纹理的场景并恢复定位。"
            return
        }
        guard !vertexOnly || pending == nil else { return }
        refreshAnchorTransforms(frame)
        ensureBase(at: hit.position)
        let raw = basePosition(hit.position)
        var next = document
        var nextPending = pending
        do {
            if let line = pending {
                guard line.mode == model.mode, line.tip == model.tip else {
                    throw DrawingError(message: "取点方式或笔尖偏移改变，请撤销起点后重新取点。")
                }
                try next.addMeasuredLine(from: line.start, to: raw, constraint: line.constraint,
                                         sample: sampleDetails(frame))
                nextPending = nil
            } else {
                let id = try next.addVertex(raw, observed: raw, sample: sampleDetails(frame))
                if !vertexOnly {
                    nextPending = PendingLine(start: id, mode: model.mode, tip: model.tip,
                                              constraint: model.constraint, trackingEpoch: trackingEpoch)
                }
            }
            remember()
            for i in next.segments.indices where !document.segments.contains(where: { $0.id == next.segments[i].id }) {
                next.segments[i].color = model.ink
                next.segments[i].style = model.inkStyle
            }
            document = next
            pending = nextPending
            changed()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } catch { model.notice = error.localizedDescription }
    }

    private func remember() {
        history.append(DrawingSnapshot(document: document, pending: pending))
        if history.count > 100 { history.removeFirst() }
    }
    func beginStroke() {
        guard livePath == nil, pending == nil, !model.editorPresented,
              let frame = arView.session.currentFrame, let hit = candidate(in: frame) else { return }
        guard document.paths.count < 50, document.paths.reduce(0, { $0 + ($1.rawPoints?.count ?? $1.points.count) }) < 18000 else {
            model.notice = "当前场景笔迹较多，请导出后新建场景。"; return
        }
        refreshAnchorTransforms(frame)
        ensureBase(at: hit.position)
        sampler = StrokeSampler()
        strokeOrigin = basePosition(hit.position)
        strokeConstraint = model.constraint
        do { try sampler.append(strokeOrigin, time: frame.timestamp) } catch { return }
        livePath = DrawingPath(id: UUID(), points: sampler.points, color: model.ink, style: model.inkStyle,
                               widthMeters: Float(model.brushMM / 1000), createdAt: Date())
        model.isDrawing = true
        model.hasStart = true
    }
    func endStroke() {
        guard var path = livePath else { return }
        if let frame = arView.session.currentFrame, let hit = candidate(in: frame) {
            let p = document.projected(basePosition(hit.position), from: strokeOrigin, constraint: strokeConstraint)
            try? sampler.append(p, time: frame.timestamp, force: true)
        }
        path.points = sampler.points
        livePath = nil
        model.isDrawing = false
        if path.points.count >= 2 {
            do {
                var next = document
                try next.addStroke(path, tolerance: Float(model.simplifyMM / 1000))
                remember()
                document = next
            } catch { model.notice = error.localizedDescription }
        }
        changed()
    }

    private func changed() {
        syncDocument()
        if let frame = arView.session.currentFrame { updateGeometry(frame: frame, hit: nil) }
        do { _ = try saveSnapshot() }
        catch { model.notice = "图形已更新，但保存失败：\(error.localizedDescription)" }
    }

    private func edit(_ message: String, clearPending: Bool = false,
                      action: (inout DrawingDocument) throws -> Void) -> Bool {
        guard !model.isDrawing else { return false }
        var next = document
        do {
            try action(&next)
            try next.synchronizePathEndpoints()
            try next.validateFaces()
            for i in next.segments.indices where !document.segments.contains(where: { $0.id == next.segments[i].id }) {
                next.segments[i].color = model.ink
                next.segments[i].style = model.inkStyle
            }
            remember()
            document = next
            if clearPending { pending = nil }
            changed()
            model.editMessage = message
            return true
        } catch {
            model.editMessage = error.localizedDescription
            return false
        }
    }

    func addManualLine(from start: UUID, direction: AxisDirection, lengthCM: Float) {
        _ = edit("已按输入长度添加线段。", clearPending: pending?.start == start) {
            _ = try $0.addManualLine(from: start, direction: direction, lengthCM: lengthCM)
        }
    }
    func mergePoints(_ a: UUID, into b: UUID) {
        guard pending == nil else { model.editMessage = "请先完成当前线段。"; return }
        _ = edit("顶点已合并，连接关系已更新；可撤销。") { try $0.mergeVertex(a, into: b) }
    }
    func createFace(_ ids: [UUID]) {
        _ = edit("已生成彩色三角面。") { try $0.addFace(ids, color: model.ink) }
    }
    func paintLine(_ id: UUID) {
        _ = edit("线段颜色和笔触已更新。") { doc in
            if let i = doc.paths.firstIndex(where: { $0.id == id }) {
                doc.paths[i].color = model.ink; doc.paths[i].style = model.inkStyle
                return
            }
            guard let i = doc.segments.firstIndex(where: { $0.id == id }) else { return }
            doc.segments[i].color = model.ink; doc.segments[i].style = model.inkStyle
        }
    }
    func paintFace(_ id: UUID) {
        _ = edit("平面颜色已更新。") { doc in
            if let i = doc.faces.firstIndex(where: { $0.id == id }) { doc.faces[i].color = model.ink }
        }
    }
    func deleteFace(_ id: UUID) {
        _ = edit("面已删除，顶点和线段保留。") { $0.faces.removeAll { $0.id == id } }
    }
    func resizeLine(_ id: UUID, lengthCM: Float) {
        _ = edit("已修改长度；连续笔迹按整体比例调整，共享端点同步更新。") { try $0.resize(id, lengthCM: lengthCM) }
    }
    func shortenLine(_ id: UUID, byCM: Float) {
        _ = edit("已缩短线段；共享终点的线段也已更新。") { try $0.shorten(id, byCM: byCM) }
    }
    func correctLine(_ id: UUID, constraint: LineConstraint) {
        _ = edit("已将终点投影到所选方向。长度可能变化，可再输入目标长度。") {
            try $0.correct(id, constraint: constraint)
        }
    }
    func calibrateAxes(origin: UUID, toward x: UUID) {
        guard pending == nil else {
            model.editMessage = "请先完成或撤销正在取点的线段，再校正坐标。"
            return
        }
        _ = edit("XY 轴与原点已校正；图形的实际位置保持不变。") { try $0.calibrateAxes(origin: origin, toward: x) }
    }
    func continueFromVertex(_ id: UUID) {
        guard pending == nil else { model.editMessage = "请先完成或撤销当前起点。"; return }
        guard model.isTracking, !model.isInterrupted else {
            model.editMessage = "请先关闭编辑器恢复相机定位，再从已有点取终点。手动添加仍可使用。"
            return
        }
        guard (try? document.vertex(id)) != nil else { return }
        remember()
        pending = PendingLine(start: id, mode: model.mode, tip: model.tip,
                              constraint: model.constraint, trackingEpoch: trackingEpoch)
        changed()
        model.editorPresented = false
    }

    func undo() {
        if model.isDrawing { endStroke() }
        guard let previous = history.popLast() else { return }
        document = previous.document
        pending = previous.pending
        if document.vertices.isEmpty && document.paths.isEmpty {
            if let anchor = baseAnchor { arView.session.remove(anchor: anchor) }
            baseAnchor = nil
            baseTransform = matrix_identity_float4x4
        }
        changed()
        model.editMessage = "已撤销上一步。"
    }

    private func syncDocument() {
        model.pathCount = document.paths.count
        model.faces = document.faces
        model.hasStart = pending != nil || model.isDrawing
        model.canUndo = !history.isEmpty
        model.axesDescription = document.axes.description
        model.vertices = document.vertices.map {
            VertexSummary(id: $0.id, name: $0.name, coordinatesCM: document.axes.coordinates($0.position) * 100)
        }
        model.segments = document.segments.enumerated().compactMap { index, line in
            guard let a = try? document.vertex(line.start), let b = try? document.vertex(line.end) else { return nil }
            return SegmentSummary(id: line.id, number: index + 1, lengthCM: simd_distance(a.position, b.position) * 100,
                                  startName: a.name, endName: b.name, operation: line.lastOperation)
        }
        model.segments += document.paths.enumerated().map { index, path in
            SegmentSummary(id: path.id, number: document.segments.count + index + 1, lengthCM: path.length * 100,
                           startName: path.start.flatMap { try? document.vertex($0).name } ?? "起点",
                           endName: path.end.flatMap { try? document.vertex($0).name } ?? "终点",
                           operation: path.operation, isPolyline: true)
        }
        for node in pathNodes.values { node.removeFromParentNode() }
        pathNodes.removeAll()
        for id in Array(dots.keys) where !document.vertices.contains(where: { $0.id == id }) {
            dots.removeValue(forKey: id)?.removeFromParentNode()
        }
        for id in Array(lines.keys) where !document.segments.contains(where: { $0.id == id }) {
            lines.removeValue(forKey: id)?.removeFromParentNode()
        }
        for vertex in document.vertices where dots[vertex.id] == nil {
            let sphere = SCNSphere(radius: 0.0018)
            sphere.segmentCount = 12
            sphere.firstMaterial = Self.material(color: .systemOrange)
            let node = SCNNode(geometry: sphere)
            world.addChildNode(node)
            dots[vertex.id] = node
        }
        for line in document.segments where lines[line.id] == nil {
            let node = Self.lineNode(color: .systemMint)
            world.addChildNode(node)
            lines[line.id] = node
        }
        for line in document.segments {
            lines[line.id]?.geometry = Self.lineNode(color: Self.uiColor(line.color)).geometry
            let material = Self.material(color: Self.uiColor(line.color))
            if line.style == .pencil {
                material.multiply.contents = Self.pencilTexture
                material.transparency = 0.92
            }
            lines[line.id]?.geometry?.firstMaterial = material
        }
        for node in faceNodes.values { node.removeFromParentNode() }
        faceNodes.removeAll()
        for face in document.faces {
            let vertices = face.vertices.compactMap { try? document.vertex($0).position }.map { SCNVector3($0) }
            guard vertices.count == 3 else { continue }
            let source = SCNGeometrySource(vertices: vertices)
            let element = SCNGeometryElement(indices: [Int32(0), 1, 2], primitiveType: .triangles)
            let geometry = SCNGeometry(sources: [source], elements: [element])
            let material = Self.material(color: Self.uiColor(face.color))
            material.isDoubleSided = true
            material.transparency = 0.42
            material.writesToDepthBuffer = false
            geometry.firstMaterial = material
            let node = SCNNode(geometry: geometry)
            world.addChildNode(node); faceNodes[face.id] = node
        }
        preview.isHidden = true
        model.liveLengthCM = nil
    }

    private func refreshAnchorTransforms(_ frame: ARFrame) {
        guard let id = baseAnchor?.identifier,
              let anchor = frame.anchors.first(where: { $0.identifier == id }) else { return }
        baseTransform = anchor.transform
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard running else { return }
        if !model.hasStart, model.tip.enabled, model.tip.corner != nil,
           let corner = currentUpperLeftCorner, corner != model.tip.corner {
            model.selectCurrentCorner()
        }
        refreshAnchorTransforms(frame)
        if case .normal = frame.camera.trackingState {
            model.isTracking = !model.isInterrupted
        } else {
            if model.isTracking { trackingEpoch += 1 }
            model.isTracking = false
        }
        let hit = candidate(in: frame)
        if livePath != nil {
            if let hit = hit {
                do {
                    let p = document.projected(basePosition(hit.position), from: strokeOrigin, constraint: strokeConstraint)
                    try sampler.append(p, time: frame.timestamp)
                    livePath?.points = sampler.points
                } catch {
                    endStroke()
                    model.notice = error.localizedDescription
                }
            } else {
                endStroke()
                model.notice = "跟踪中断，已保存中断前的笔迹。重新定位后按住继续。"
            }
        }
        // Tracking itself runs at the camera frame rate; only UI/meshes are
        // throttled. There is no acceleration integration or 1-second polling.
        guard frame.timestamp - lastUIUpdate >= 1.0 / 20.0 else { return }
        lastUIUpdate = frame.timestamp
        updateGeometry(frame: frame, hit: hit)
        updateStatus(frame: frame, hit: hit)
    }

    private func updateStatus(frame: ARFrame, hit: Candidate?) {
        model.canCapture = hit != nil && !pendingTrackingLost
        if model.isInterrupted { return }
        switch frame.camera.trackingState {
        case .notAvailable:
            model.trackingText = "跟踪暂不可用"
            model.hint = "请检查相机权限，或清除并重新定位。"
        case .limited(let reason):
            model.trackingText = "正在定位"
            switch reason {
            case .initializing: model.hint = "缓慢左右移动，让镜头看到有文字或纹理的区域。"
            case .excessiveMotion: model.hint = "移动过快，请放慢，让画面保持清晰。"
            case .insufficientFeatures: model.hint = "场景特征不足，换到明亮、有纹理的区域。"
            case .relocalizing: model.hint = "请对准之前看过的场景，正在找回原点。"
            @unknown default: model.hint = "请慢慢移动，等待恢复跟踪。"
            }
        case .normal:
            model.trackingText = "已定位"
            if pendingTrackingLost {
                model.hint = "本条线段中途丢失过跟踪，请点撤销并重新记录起点。"
            } else if model.isDrawing {
                model.hint = "移动左上角虚拟笔尖；松手结束这一笔。"
            } else if model.settingsPresented || model.editorPresented {
                model.hint = "关闭设置后继续取点。"
            } else if model.mode == .surface && hit == nil {
                model.hint = "将中央准星对准附近表面，缓慢换个视角。也可切换设备画笔，无需命中表面。"
            } else if model.hasStart {
                model.hint = model.mode == .device
                    ? "移动设备笔尖到终点，再点一次。\(originInView ? "" : "起点在画面外。")"
                    : "用中央准星指向终点，再点一次。\(originInView ? "" : "起点在画面外。")"
            } else {
                model.hint = model.mode == .device
                    ? "把设备笔尖放到起点，点击记录；不必等待识别平面。"
                    : "\(hit?.source ?? "")，点击记录起点。"
            }
        }
    }

    private func updateGeometry(frame: ARFrame, hit: Candidate?) {
        let tracking = model.isTracking && !model.isInterrupted
        world.isHidden = !tracking
        var labels: [ScreenLabel] = []
        if let hit = hit, model.mode == .device,
           let screen = project(hit.position, camera: frame.camera) {
            labels.append(ScreenLabel(id: tipLabelID, text: "⊕ 笔尖", point: screen, isStart: true))
        }
        let transform = simd_float4x4(columns: (SIMD4(baseX, 0), SIMD4(baseY, 0), SIMD4(0, 1, 0, 0), baseTransform.columns.3))
        for node in faceNodes.values { node.simdTransform = transform }
        originInView = false
        for point in document.vertices {
            let p = worldPosition(point.position)
            dots[point.id]?.simdPosition = p
            guard tracking, let screen = project(p, camera: frame.camera) else { continue }
            let isOrigin = simd_distance(point.position, document.axes.origin) < 0.0001
            let text = point.name + (isOrigin ? " · 原点" : (pending?.start == point.id ? " · 起点" : ""))
            labels.append(ScreenLabel(id: point.id, text: text, point: screen, isStart: isOrigin || pending?.start == point.id))
            if pending?.start == point.id || (pending == nil && isOrigin) { originInView = true }
        }
        if !document.vertices.isEmpty,
           !document.vertices.contains(where: { simd_distance($0.position, document.axes.origin) < 0.0001 }),
           tracking, let screen = project(worldPosition(document.axes.origin), camera: frame.camera) {
            labels.append(ScreenLabel(id: originLabelID, text: "O · 原点", point: screen, isStart: true))
        }
        model.labels = labels
        let camera = frame.camera.transform.columns.3.xyz
        let right = frame.camera.transform.columns.0.xyz
        for stroke in document.segments {
            if let a = try? document.vertex(stroke.start), let b = try? document.vertex(stroke.end), let line = lines[stroke.id] {
                if stroke.style == .pencil {
                    line.simdTransform = matrix_identity_float4x4
                    line.geometry = RibbonRenderer.geometry(points: [worldPosition(a.position), worldPosition(b.position)],
                        camera: camera, cameraRight: right, width: 0.0025,
                        material: RibbonRenderer.material(color: stroke.color, style: .pencil))
                } else { placeLine(line, from: worldPosition(a.position), to: worldPosition(b.position)) }
            }
        }
        var paths = document.paths
        if let path = livePath { paths.append(path) }
        let activeIDs = Set(paths.map(\.id))
        for id in Array(pathNodes.keys) where !activeIDs.contains(id) {
            pathNodes.removeValue(forKey: id)?.removeFromParentNode()
        }
        for path in paths {
            let node: SCNNode
            if let existing = pathNodes[path.id] { node = existing }
            else { node = SCNNode(); pathNodes[path.id] = node; world.addChildNode(node) }
            let material = node.geometry?.firstMaterial ?? RibbonRenderer.material(color: path.color, style: path.style)
            node.geometry = RibbonRenderer.geometry(points: path.points.map { worldPosition($0) }, camera: camera,
                                                    cameraRight: right, width: path.widthMeters, material: material)
        }
        if let hit = hit, baseAnchor != nil {
            model.relativeCM = document.axes.coordinates(basePosition(hit.position)) * 100
        } else { model.relativeCM = nil }
        if !pendingTrackingLost, tracking, let line = pending,
           let a = try? document.vertex(line.start), let hit = hit {
            let target = document.projected(basePosition(hit.position), from: a.position, constraint: line.constraint)
            placeLine(preview, from: worldPosition(a.position), to: worldPosition(target))
            model.liveLengthCM = simd_distance(a.position, target) * 100
        } else {
            preview.isHidden = true
            model.liveLengthCM = nil
        }
    }

    private func project(_ p: SIMD3<Float>, camera: ARCamera) -> CGPoint? {
        let local = simd_inverse(camera.transform) * SIMD4(p.x, p.y, p.z, 1)
        let projected = arView.projectPoint(SCNVector3(p))
        let screen = CGPoint(x: CGFloat(projected.x), y: CGFloat(projected.y))
        guard local.z < -0.02, projected.z >= 0, projected.z <= 1,
              arView.bounds.insetBy(dx: 24, dy: 30).contains(screen) else { return nil }
        return screen
    }

    private static func material(color: UIColor) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = color
        return material
    }

    private static func lineNode(color: UIColor) -> SCNNode {
        let box = SCNCylinder(radius: 0.5, height: 1)
        box.radialSegmentCount = 8
        box.firstMaterial = material(color: color)
        return SCNNode(geometry: box)
    }
    private static func uiColor(_ ink: InkColor) -> UIColor {
        let c = ink.rgb
        return UIColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
    }
    private static let pencilTexture: UIImage = {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 256))
        return renderer.image { ctx in
            var seed: UInt32 = 417
            for y in 0..<256 {
                for x in 0..<64 {
                    seed = seed &* 1664525 &+ 1013904223
                    let value = CGFloat(seed % 100) / 250 + 0.6
                    ctx.cgContext.setFillColor(UIColor(white: value, alpha: 1).cgColor)
                    ctx.cgContext.fill(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
    }()

    private func placeLine(_ entity: SCNNode, from a: SIMD3<Float>, to b: SIMD3<Float>) {
        let delta = b - a
        let length = simd_length(delta)
        guard length.isFinite, length > 0.0001 else { entity.isHidden = true; return }
        entity.isHidden = false
        entity.simdPosition = (a + b) / 2
        // A unit box stretched along local Y avoids rebuilding meshes per frame.
        entity.simdScale = SIMD3(0.0025, length, 0.0025)
        entity.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: delta / length)
    }

    private func markTrackingUnavailable(_ text: String, hint: String) {
        endStroke()
        model.isTracking = false
        model.canCapture = false
        model.trackingText = text
        model.hint = hint
        model.liveLengthCM = nil
        model.relativeCM = nil
        model.labels = []
        world.isHidden = true
        trackingEpoch += 1
    }

    func sessionWasInterrupted(_ session: ARSession) {
        model.isInterrupted = true
        markTrackingUnavailable("相机被中断", hint: "返回应用后，对准之前看过的区域找回原点。")
    }
    func sessionInterruptionEnded(_ session: ARSession) {
        model.isInterrupted = false
        model.trackingText = "正在找回原点"
    }
    func session(_ session: ARSession, didFailWithError error: Error) {
        running = false
        markTrackingUnavailable("跟踪出错", hint: error.localizedDescription)
        model.notice = "ARKit 出错：\(error.localizedDescription)\n可先导出已有线段，再清除并重新定位。"
    }
    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool { true }
    func coachingOverlayViewDidRequestSessionReset(_ coachingOverlayView: ARCoachingOverlayView) {
        if document.vertices.isEmpty && document.paths.isEmpty { restart() }
        else { model.notice = "场景中有已记录的点。可先导出，再从“更多”清除并重新定位。" }
    }

    func exportMeasurements() {
        if let frame = arView.session.currentFrame { refreshAnchorTransforms(frame) }
        do { model.exportFile = ExportFile(url: try saveSnapshot()) }
        catch { model.notice = "导出失败：\(error.localizedDescription)" }
    }

    @discardableResult
    private func saveSnapshot() throws -> URL {
        func xyz(_ point: SIMD3<Float>) -> [Float] { [point.x, point.y, point.z] }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let rawDocument = try JSONSerialization.jsonObject(with: encoder.encode(document))
        let records: [[String: Any]] = document.segments.compactMap { line in
            guard let a = try? document.vertex(line.start), let b = try? document.vertex(line.end) else { return nil }
            return ["id": line.id.uuidString, "startVertex": a.id.uuidString, "endVertex": b.id.uuidString,
                    "start": xyz(document.axes.coordinates(a.position)), "end": xyz(document.axes.coordinates(b.position)),
                    "startWorldARKit": xyz(worldPosition(a.position)), "endWorldARKit": xyz(worldPosition(b.position)),
                    "length": simd_distance(a.position, b.position), "source": line.source,
                    "lastOperation": line.lastOperation]
        }
        let snapshot: [String: Any] = [
            "schemaVersion": 2,
            "sessionID": sessionID.uuidString,
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "units": "meters",
            "coordinateSystem": "right-handed user frame: X/Y horizontal, Z up; X calibrated by two vertices",
            "coordinateDefinition": document.axes.description,
            "worldCoordinateSystem": "ARKit native: Y up",
            "baseAnchorWorldTransformColumns": (0..<4).map { i in
                let c = baseTransform[i]; return [c.x, c.y, c.z, c.w]
            },
            "document": rawDocument,
            "trackingNormalAtExport": model.isTracking,
            "pendingStartVertex": pending?.start.uuidString as Any? ?? NSNull(),
            "segments": records
        ]

        let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys])
        let folder = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
            .appendingPathComponent("SpatialPen", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("measurement-\(sessionID.uuidString).json")
        try data.write(to: file, options: .atomic)
        return file
    }
}

private extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
