import Foundation
import simd

enum InkColor: String, Codable, CaseIterable, Identifiable {
    case graphite = "石墨", white = "白", red = "珊瑚红", yellow = "金黄", green = "薄荷绿", blue = "蓝", purple = "紫"
    var id: String { rawValue }
    var rgb: SIMD3<Float> {
        switch self {
        case .graphite: return SIMD3(0.18, 0.20, 0.24)
        case .white: return SIMD3(0.95, 0.95, 0.92)
        case .red: return SIMD3(0.95, 0.28, 0.27)
        case .yellow: return SIMD3(1, 0.73, 0.17)
        case .green: return SIMD3(0.20, 0.85, 0.65)
        case .blue: return SIMD3(0.20, 0.55, 1)
        case .purple: return SIMD3(0.70, 0.40, 0.95)
        }
    }
}
enum InkStyle: String, Codable, CaseIterable, Identifiable {
    case pencil = "铅笔", solid = "实线"
    var id: String { rawValue }
}
struct DrawingFace: Identifiable, Codable {
    let id: UUID
    var vertices: [UUID]
    var color: InkColor
}
struct DrawingPath: Identifiable, Codable {
    let id: UUID
    var points: [SIMD3<Float>]
    var color: InkColor
    var style: InkStyle
    var widthMeters: Float
    let createdAt: Date
    var rawPoints: [SIMD3<Float>]? = nil
    var toleranceMeters: Float? = nil
    var start: UUID? = nil
    var end: UUID? = nil
    var operation = "连续笔迹"
    var length: Float {
        zip(points, points.dropFirst()).reduce(0) { $0 + simd_distance($1.0, $1.1) }
    }
}

enum PolylineSimplifier {
    static func distance(_ p: SIMD3<Float>, to a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let d = b - a
        let denominator = simd_length_squared(d)
        if denominator < 1e-12 { return simd_distance(p, a) }
        let t = min(1, max(0, simd_dot(p - a, d) / denominator))
        return simd_distance(p, a + t * d)
    }
    // Iterative 3D Ramer-Douglas-Peucker. Keep endpoint order; no recursive stack growth.
    static func simplify(_ points: [SIMD3<Float>], tolerance: Float) -> [SIMD3<Float>] {
        guard points.count > 2, tolerance.isFinite, tolerance > 0 else { return points }
        var keep = Set([0, points.count - 1])
        var work = [(0, points.count - 1)]
        while let (a, b) = work.popLast() {
            guard b > a + 1 else { continue }
            var maximum = tolerance
            var split: Int?
            for i in (a + 1)..<b {
                let error = distance(points[i], to: points[a], points[b])
                if error > maximum { maximum = error; split = i }
            }
            if let i = split {
                keep.insert(i)
                work.append((a, i)); work.append((i, b))
            }
        }
        return keep.sorted().map { points[$0] }
    }
}

// Samples only real displacement. A rejected jump never becomes a long connecting edge.
struct StrokeSampler {
    private(set) var points: [SIMD3<Float>] = []
    private var lastObserved: SIMD3<Float>?
    private var lastTime: TimeInterval?
    mutating func append(_ point: SIMD3<Float>, time: TimeInterval, force: Bool = false) throws {
        try DrawingDocument.checkPosition(point)
        guard time.isFinite else { throw DrawingError(message: "采样时间无效。") }
        if let previous = lastObserved, let stamp = lastTime {
            guard time > stamp else { return }
            let dt = time - stamp
            guard dt <= 0.5, simd_distance(point, previous) <= min(0.15, 0.015 + Float(dt) * 3) else {
                throw DrawingError(message: "位置发生跳变或采样中断，已结束这一笔。")
            }
        }
        lastTime = time; lastObserved = point
        if let last = points.last, simd_distance(last, point) < (force ? 0.0002 : 0.002) { return }
        guard points.count < 2000 else { throw DrawingError(message: "这一笔已达到采样上限，请松手后继续画。") }
        points.append(point)
    }
}

enum LineConstraint: String, CaseIterable, Identifiable, Codable {
    case free = "自由", horizontal = "水平 XY", x = "沿 X", y = "沿 Y", z = "竖直 Z"
    var id: String { rawValue }
}

enum AxisDirection: String, CaseIterable, Identifiable {
    case plusX = "+X", minusX = "−X", plusY = "+Y", minusY = "−Y", plusZ = "+Z 向上", minusZ = "−Z 向下"
    var id: String { rawValue }
    var vector: SIMD3<Float> {
        switch self {
        case .plusX: return SIMD3(1, 0, 0)
        case .minusX: return SIMD3(-1, 0, 0)
        case .plusY: return SIMD3(0, 1, 0)
        case .minusY: return SIMD3(0, -1, 0)
        case .plusZ: return SIMD3(0, 0, 1)
        case .minusZ: return SIMD3(0, 0, -1)
        }
    }
}

struct DrawingError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// All stored geometry uses meters in one rigid, Z-up AR anchor frame.
// Changing the user axes only changes coordinate interpretation, never vertices.
struct DrawingAxes: Codable {
    var origin: SIMD3<Float> = .zero
    var x: SIMD3<Float> = SIMD3(1, 0, 0)
    var y: SIMD3<Float> { simd_cross(SIMD3(0, 0, 1), x) }
    var description = "XY 水平，Z 向上；X 暂用初始定位方向"

    func coordinates(_ base: SIMD3<Float>) -> SIMD3<Float> {
        let d = base - origin
        return SIMD3(simd_dot(d, x), simd_dot(d, y), d.z)
    }
    func direction(_ local: SIMD3<Float>) -> SIMD3<Float> {
        x * local.x + y * local.y + SIMD3(0, 0, local.z)
    }
}

struct SampleDetails: Codable {
    let mode: String
    let tipOffsetCameraMeters: SIMD3<Float>
    let physicalCorner: String?
    let estimatedTipGeometry: Bool
    let frameTime: TimeInterval
}

struct DrawingVertex: Identifiable, Codable {
    let id: UUID
    let number: Int
    var position: SIMD3<Float>
    // Preserve the original AR observation when a constraint or later edit changes it.
    let observedPosition: SIMD3<Float>?
    let sample: SampleDetails?
    let createdAt: Date
    var edited = false
    var name: String { "V\(number)" }
}

struct DrawingSegment: Identifiable, Codable {
    let id: UUID
    var start: UUID
    var end: UUID
    let source: String
    let createdAt: Date
    var lastOperation: String
    var color: InkColor = .green
    var style: InkStyle = .pencil
}

struct DrawingDocument: Codable {
    var vertices: [DrawingVertex] = []
    var segments: [DrawingSegment] = []
    var axes = DrawingAxes()
    var faces: [DrawingFace] = []
    var paths: [DrawingPath] = []

    mutating func addStroke(_ stroke: DrawingPath, tolerance: Float) throws {
        guard stroke.points.count >= 2 else { throw DrawingError(message: "笔迹太短。") }
        guard tolerance.isFinite, tolerance >= 0 else { throw DrawingError(message: "简化阈值无效。") }
        for p in stroke.points { try Self.checkPosition(p) }
        var next = self
        var path = stroke
        path.rawPoints = stroke.points
        path.toleranceMeters = tolerance
        path.points = PolylineSimplifier.simplify(stroke.points, tolerance: tolerance)
        guard path.length >= 0.001 else { throw DrawingError(message: "笔迹太短。") }
        path.start = try next.addVertex(path.points[0], observed: stroke.points[0])
        path.end = try next.addVertex(path.points[path.points.count - 1], observed: stroke.points.last)
        path.operation = "连续笔迹 · 已简化"
        next.paths.append(path)
        self = next
    }

    mutating func synchronizePathEndpoints() throws {
        for i in paths.indices {
            guard paths[i].points.count >= 2 else { throw DrawingError(message: "笔迹数据不完整。") }
            if let a = paths[i].start { paths[i].points[0] = try vertex(a).position }
            if let b = paths[i].end { paths[i].points[paths[i].points.count - 1] = try vertex(b).position }
            guard paths[i].length >= 0.001 else { throw DrawingError(message: "操作会使笔迹退化，已取消。") }
        }
    }

    private mutating func replacePathPoints(_ index: Int, _ points: [SIMD3<Float>], operation: String) throws {
        var next = self
        if next.paths[index].start != nil, next.paths[index].start == next.paths[index].end,
           simd_distance(points[0], points[points.count - 1]) > 0.0001 {
            throw DrawingError(message: "首尾共用一个顶点，不能单独移动末端。请先撤销首尾合并。")
        }
        for p in points { try Self.checkPosition(p) }
        next.paths[index].points = points
        next.paths[index].operation = operation
        for (id, p) in [(next.paths[index].start, points[0]), (next.paths[index].end, points[points.count - 1])] {
            if let id = id, let v = next.vertices.firstIndex(where: { $0.id == id }) {
                next.vertices[v].position = p; next.vertices[v].edited = true
            }
        }
        for line in next.segments { try Self.checkLength(next.length(line)) }
        try next.synchronizePathEndpoints()
        try next.validateFaces()
        self = next
    }

    func validateFaces() throws {
        for face in faces {
            guard Set(face.vertices).count == 3 else { throw DrawingError(message: "操作会使面退化，已取消。") }
            let p = try face.vertices.map { try vertex($0).position }
            guard simd_length(simd_cross(p[1] - p[0], p[2] - p[0])) > 0.00001 else {
                throw DrawingError(message: "三个顶点太接近或共线，不能形成面。")
            }
        }
    }
    mutating func addFace(_ ids: [UUID], color: InkColor) throws {
        guard ids.count == 3, Set(ids).count == 3 else { throw DrawingError(message: "请选择三个不同顶点。") }
        guard !faces.contains(where: { Set($0.vertices) == Set(ids) }) else { throw DrawingError(message: "这个面已存在，可直接改色。") }
        var next = self
        next.faces.append(DrawingFace(id: UUID(), vertices: ids, color: color))
        try next.validateFaces()
        self = next
    }
    mutating func mergeVertex(_ source: UUID, into target: UUID) throws {
        guard source != target else { throw DrawingError(message: "请选择两个不同顶点。") }
        _ = try vertex(source); _ = try vertex(target)
        var next = self
        for i in next.segments.indices {
            if next.segments[i].start == source { next.segments[i].start = target }
            if next.segments[i].end == source { next.segments[i].end = target }
            next.segments[i].lastOperation = "顶点合并"
        }
        next.segments.removeAll { $0.start == $0.end }
        var seen: Set<Set<UUID>> = []
        next.segments = next.segments.filter { seen.insert(Set([$0.start, $0.end])).inserted }
        for i in next.faces.indices { next.faces[i].vertices = next.faces[i].vertices.map { $0 == source ? target : $0 } }
        for i in next.paths.indices {
            if next.paths[i].start == source { next.paths[i].start = target }
            if next.paths[i].end == source { next.paths[i].end = target }
        }
        next.vertices.removeAll { $0.id == source }
        for line in next.segments { try Self.checkLength(next.length(line)) }
        try next.validateFaces()
        try next.synchronizePathEndpoints()
        self = next
    }

    func vertex(_ id: UUID) throws -> DrawingVertex {
        guard let point = vertices.first(where: { $0.id == id }) else {
            throw DrawingError(message: "请先选择已有顶点。")
        }
        return point
    }
    func segment(_ id: UUID) throws -> DrawingSegment {
        guard let line = segments.first(where: { $0.id == id }) else {
            throw DrawingError(message: "请先选择线段。")
        }
        return line
    }
    func length(_ segment: DrawingSegment) throws -> Float {
        simd_distance(try vertex(segment.start).position, try vertex(segment.end).position)
    }
    static func checkLength(_ meters: Float) throws {
        guard meters.isFinite, meters >= 0.001, meters <= 100 else {
            throw DrawingError(message: "长度请输入 0.1–10000 厘米的有限数值。")
        }
    }
    static func checkPosition(_ p: SIMD3<Float>) throws {
        guard p.x.isFinite, p.y.isFinite, p.z.isFinite, simd_length(p) <= 1000 else {
            throw DrawingError(message: "坐标无效或超出绘图范围。")
        }
    }
    @discardableResult
    mutating func addVertex(_ p: SIMD3<Float>, observed: SIMD3<Float>? = nil,
                            sample: SampleDetails? = nil) throws -> UUID {
        try Self.checkPosition(p)
        let id = UUID()
        vertices.append(DrawingVertex(id: id, number: (vertices.map(\.number).max() ?? 0) + 1,
                                      position: p, observedPosition: observed, sample: sample,
                                      createdAt: Date(), edited: observed.map { simd_distance($0, p) > 0.00001 } ?? false))
        return id
    }
    func projected(_ end: SIMD3<Float>, from start: SIMD3<Float>, constraint: LineConstraint) -> SIMD3<Float> {
        let d = end - start
        switch constraint {
        case .free: return end
        case .horizontal: return SIMD3(end.x, end.y, start.z)
        case .x: return start + axes.x * simd_dot(d, axes.x)
        case .y: return start + axes.y * simd_dot(d, axes.y)
        case .z: return start + SIMD3(0, 0, d.z)
        }
    }
    @discardableResult
    mutating func addMeasuredLine(from startID: UUID, to raw: SIMD3<Float>,
                                  constraint: LineConstraint, sample: SampleDetails?) throws -> UUID {
        let start = try vertex(startID).position
        try Self.checkPosition(raw)
        let end = projected(raw, from: start, constraint: constraint)
        try Self.checkLength(simd_distance(start, end))
        let endID = try addVertex(end, observed: raw, sample: sample)
        segments.append(DrawingSegment(id: UUID(), start: startID, end: endID, source: "AR 取点",
                                       createdAt: Date(), lastOperation: constraint.rawValue))
        return endID
    }
    @discardableResult
    mutating func addManualLine(from startID: UUID, direction: AxisDirection, lengthCM: Float) throws -> UUID {
        let length = lengthCM / 100
        try Self.checkLength(length)
        let start = try vertex(startID).position
        let endID = try addVertex(start + axes.direction(direction.vector) * length)
        segments.append(DrawingSegment(id: UUID(), start: startID, end: endID, source: "手动输入",
                                       createdAt: Date(), lastOperation: direction.rawValue))
        return endID
    }
    mutating func calibrateAxes(origin originID: UUID, toward xID: UUID) throws {
        let a = try vertex(originID)
        let b = try vertex(xID)
        let delta = b.position - a.position
        let flat = SIMD3<Float>(delta.x, delta.y, 0)
        guard simd_length(flat) >= 0.01 else {
            throw DrawingError(message: "两点的水平间距至少需要 1 厘米；不能用同一点或上下重叠的两点确定 X。")
        }
        axes.origin = a.position
        axes.x = simd_normalize(flat)
        axes.description = "原点：\(a.name) 校正时位置；+X：\(a.name) → \(b.name) 的水平方向；Z 向上"
    }
    private mutating func moveEnd(of line: DrawingSegment, to p: SIMD3<Float>, operation: String) throws {
        try Self.checkPosition(p)
        // Shared vertices remain shared. Reject edits which collapse any connected edge.
        for connected in segments where connected.start == line.end || connected.end == line.end {
            let otherID = connected.start == line.end ? connected.end : connected.start
            let other = try vertex(otherID).position
            try Self.checkLength(simd_distance(other, p))
        }
        guard let index = vertices.firstIndex(where: { $0.id == line.end }) else { return }
        var proposed = self
        proposed.vertices[index].position = p
        try proposed.validateFaces()
        vertices[index].position = p
        vertices[index].edited = true
        for i in segments.indices where segments[i].start == line.end || segments[i].end == line.end {
            segments[i].lastOperation = segments[i].id == line.id ? operation : "共享顶点已移动"
        }
    }
    mutating func resize(_ id: UUID, lengthCM: Float) throws {
        let meters = lengthCM / 100
        try Self.checkLength(meters)
        if let i = paths.firstIndex(where: { $0.id == id }) {
            let path = paths[i]
            guard path.length >= 0.001 else { throw DrawingError(message: "笔迹太短。") }
            let start = path.points[0]
            let points = path.points.map { start + ($0 - start) * (meters / path.length) }
            try replacePathPoints(i, points, operation: "整条按比例改长度")
            return
        }
        let line = try segment(id)
        let start = try vertex(line.start).position
        let end = try vertex(line.end).position
        let oldLength = simd_distance(start, end)
        guard oldLength >= 0.001 else { throw DrawingError(message: "线段太短，无法确定方向。") }
        try moveEnd(of: line, to: start + (end - start) / oldLength * meters, operation: "手动改长度")
    }
    mutating func shorten(_ id: UUID, byCM: Float) throws {
        guard byCM.isFinite, byCM > 0 else { throw DrawingError(message: "减少量必须大于 0 厘米。") }
        if let i = paths.firstIndex(where: { $0.id == id }) {
            let path = paths[i]
            var remaining = path.length - byCM / 100
            try Self.checkLength(remaining)
            var points = [path.points[0]]
            for (a, b) in zip(path.points, path.points.dropFirst()) {
                let edge = simd_distance(a, b)
                if edge < 0.000001 { continue }
                if remaining <= edge { points.append(a + (b - a) * (remaining / edge)); break }
                points.append(b); remaining -= edge
            }
            try replacePathPoints(i, points, operation: "从末端缩短")
            return
        }
        let current = try length(segment(id)) * 100
        try resize(id, lengthCM: current - byCM)
    }
    mutating func correct(_ id: UUID, constraint: LineConstraint) throws {
        if let i = paths.firstIndex(where: { $0.id == id }) {
            let points = paths[i].points
            let projected = points.map { self.projected($0, from: points[0], constraint: constraint) }
            let simplified = PolylineSimplifier.simplify(projected, tolerance: 0.0001)
            try replacePathPoints(i, simplified, operation: "整条方向矫正：" + constraint.rawValue)
            return
        }
        let line = try segment(id)
        let a = try vertex(line.start).position
        let b = try vertex(line.end).position
        let target = projected(b, from: a, constraint: constraint)
        try Self.checkLength(simd_distance(a, target))
        try moveEnd(of: line, to: target, operation: "方向矫正：" + constraint.rawValue)
    }
}
