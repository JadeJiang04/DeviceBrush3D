import Foundation
import simd
import Darwin

func runGeometryChecks() -> (Int, [String]) {
    var count = 0
    var failures: [String] = []
    func check(_ value: Bool, _ name: String) {
        count += 1
        if !value { failures.append(name) }
    }
    func close(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Bool { simd_distance(a, b) < 0.00001 }
    func reject(_ name: String, _ action: () throws -> Void) {
        do { try action(); check(false, name) } catch { check(true, name) }
    }
    do {
        var noisy: [SIMD3<Float>] = []
        for i in 0...100 {
            let x = Float(i) / 100
            let y: Float = (i == 0 || i == 100) ? 0 : sin(Float(i)) * 0.002
            noisy.append(SIMD3<Float>(x, y, 0))
        }
        let reduced = PolylineSimplifier.simplify(noisy, tolerance: 0.003)
        check(reduced.count == 2 && reduced.first == noisy.first && reduced.last == noisy.last,
              "straight stroke simplifies to endpoints")
        let elbow: [SIMD3<Float>] = [.zero, SIMD3(0.1, 0, 0), SIMD3(0.2, 0, 0),
                                    SIMD3(0.2, 0.1, 0), SIMD3(0.2, 0.2, 0)]
        check(PolylineSimplifier.simplify(elbow, tolerance: 0.003) == [elbow[0], elbow[2], elbow[4]],
              "corner retained without intermediate samples")
        let loop = elbow + [SIMD3(0, 0.2, 0), .zero]
        check(PolylineSimplifier.simplify(loop, tolerance: 0.003).count >= 4, "closed loop survives")
        let curve: [SIMD3<Float>] = (0...100).map {
            let t = Float($0) / 100
            return SIMD3<Float>(t, sin(t * 5) * 0.1, cos(t * 3) * 0.1)
        }
        let simpleCurve = PolylineSimplifier.simplify(curve, tolerance: 0.003)
        let error = curve.map { p in zip(simpleCurve, simpleCurve.dropFirst()).map {
            PolylineSimplifier.distance(p, to: $0.0, $0.1)
        }.min()! }.max()!
        check(error <= 0.003001 && simpleCurve.count < curve.count, "3D simplification error bound")
        check(PolylineSimplifier.simplify(elbow, tolerance: 0) == elbow, "zero tolerance preserves raw")
        var strokeDoc = DrawingDocument()
        let stroke = DrawingPath(id: UUID(), points: elbow, color: .blue, style: .pencil,
                                 widthMeters: 0.004, createdAt: Date())
        try strokeDoc.addStroke(stroke, tolerance: 0.003)
        check(strokeDoc.vertices.count == 2 && strokeDoc.paths[0].points.count == 3,
              "only two public vertices for bent stroke")
        check(strokeDoc.paths[0].rawPoints == elbow, "original samples retained")
        check(abs(strokeDoc.paths[0].length - 0.4) < 0.00001, "length follows polyline not chord")
        let endpoint = strokeDoc.paths[0].end!
        try strokeDoc.addManualLine(from: endpoint, direction: .plusZ, lengthCM: 10)
        try strokeDoc.resize(stroke.id, lengthCM: 20)
        let resizedEndpoint = try strokeDoc.vertex(endpoint).position
        check(abs(strokeDoc.paths[0].length - 0.2) < 0.00001 &&
              close(resizedEndpoint, SIMD3(0.1, 0.1, 0)), "scale stroke and public endpoint")
        check(abs(try strokeDoc.length(strokeDoc.segments[0]) - sqrt(0.03)) < 0.00001,
              "connected straight edge follows stroke edit")
        try strokeDoc.shorten(stroke.id, byCM: 5)
        check(abs(strokeDoc.paths[0].length - 0.15) < 0.00001 &&
              close(strokeDoc.paths[0].points.last!, SIMD3(0.1, 0.05, 0)), "trim from end along polyline")
        check(strokeDoc.paths[0].rawPoints == elbow, "edits preserve original samples")
        let pathEncoder = JSONEncoder(); pathEncoder.outputFormatting = .sortedKeys
        let beforeBadPath = try pathEncoder.encode(strokeDoc)
        reject("reject excessive path trim") { try strokeDoc.shorten(stroke.id, byCM: 99) }
        reject("reject path projection to zero") { try strokeDoc.correct(stroke.id, constraint: .z) }
        check(try pathEncoder.encode(strokeDoc) == beforeBadPath, "invalid path edits atomic")
        let strokeDecoded = try JSONDecoder().decode(DrawingDocument.self, from: pathEncoder.encode(strokeDoc))
        check(strokeDecoded.paths[0].rawPoints == elbow && strokeDecoded.paths[0].end == endpoint,
              "path topology and raw samples JSON roundtrip")
        let mergeTarget = try strokeDoc.addVertex(SIMD3(0.15, 0.05, 0))
        try strokeDoc.mergeVertex(endpoint, into: mergeTarget)
        check(strokeDoc.paths[0].end == mergeTarget &&
              close(strokeDoc.paths[0].points.last!, SIMD3(0.15, 0.05, 0)), "merge rewires stroke endpoint")
        try strokeDoc.correct(stroke.id, constraint: .x)
        check(strokeDoc.paths[0].points.count == 2 && abs(strokeDoc.paths[0].length - 0.15) < 0.00001,
              "axis correction simplifies whole stroke")
        var sampler = StrokeSampler()
        try sampler.append(.zero, time: 1)
        for i in 1...10 { try sampler.append(.zero, time: 1 + Double(i) / 30) }
        check(sampler.points.count == 1, "stationary press does not accumulate points")
        try sampler.append(SIMD3(0.01, 0, 0), time: 1.4)
        check(sampler.points.count == 2, "movement samples new point")
        try sampler.append(SIMD3(0.02, 0, 0), time: 1.4)
        check(sampler.points.count == 2, "duplicate timestamp ignored")
        reject("jump rejected") { try sampler.append(SIMD3(1, 0, 0), time: 1.43) }
        check(sampler.points.count == 2, "jump leaves prior stroke intact")
        reject("long sample gap rejected") { try sampler.append(SIMD3(0.02, 0, 0), time: 3) }
        var art = DrawingDocument()
        let va = try art.addVertex(.zero)
        let vb = try art.addManualLine(from: va, direction: .plusX, lengthCM: 20)
        let vc = try art.addManualLine(from: vb, direction: .plusY, lengthCM: 20)
        try art.addFace([va, vb, vc], color: .red)
        check(art.faces.count == 1 && art.faces[0].color == .red, "face color")
        reject("duplicate face") { try art.addFace([vc, vb, va], color: .blue) }
        reject("merge cannot collapse face") { try art.mergeVertex(vb, into: va) }
        check(art.vertices.count == 3 && art.faces.count == 1, "merge face rejection atomic")
        art.faces.removeAll()
        try art.mergeVertex(vc, into: va)
        check(art.vertices.count == 2 && art.segments.count == 1, "merge rewires and deduplicates")
        let collinear = try art.addVertex(SIMD3(0.4, 0, 0))
        reject("collinear face") { try art.addFace([va, vb, collinear], color: .blue) }
        var d = DrawingDocument()
        let a = try d.addVertex(SIMD3(1, 2, 3))
        let b = try d.addVertex(SIMD3(1, 3, 3.2))
        let original = d.vertices.map(\.position)
        try d.calibrateAxes(origin: a, toward: b)
        check(close(d.axes.coordinates(SIMD3(1, 2, 3)), .zero), "origin")
        check(close(d.axes.coordinates(SIMD3(1, 3, 3.2)), SIMD3(1, 0, 0.2)), "rotated X and Z-up")
        check(close(simd_cross(d.axes.x, d.axes.y), SIMD3(0, 0, 1)), "right handed")
        check(d.vertices.map(\.position) == original, "calibration preserves shape")
        let savedAxes = d.axes
        reject("same-point calibration") { try d.calibrateAxes(origin: a, toward: a) }
        check(d.axes.x == savedAxes.x && d.axes.origin == savedAxes.origin, "failed calibration is atomic")
        let vertical = try d.addVertex(SIMD3(1, 2, 4))
        reject("vertical calibration") { try d.calibrateAxes(origin: a, toward: vertical) }
        let m = try d.addManualLine(from: a, direction: .plusY, lengthCM: 20)
        check(close(try d.vertex(m).position, SIMD3(0.8, 2, 3)), "manual +Y in rotated frame")
        let minus = try d.addManualLine(from: a, direction: .minusZ, lengthCM: 30)
        check(close(try d.vertex(minus).position, SIMD3(1, 2, 2.7)), "manual -Z")
        let raw = SIMD3<Float>(1.3, 2.4, 3.6)
        let measured = try d.addMeasuredLine(from: a, to: raw, constraint: .horizontal, sample: nil)
        check(close(try d.vertex(measured).position, SIMD3(1.3, 2.4, 3)), "horizontal projection")
        check(try d.vertex(measured).observedPosition == raw, "preserve raw observation")
        check(abs(try d.length(d.segments.last!) - 0.5) < 0.00001, "projected 3-4-5 length")
        check(close(d.projected(raw, from: SIMD3(1, 2, 3), constraint: .x), SIMD3(1, 2.4, 3)), "X projection")
        check(close(d.projected(raw, from: SIMD3(1, 2, 3), constraint: .y), SIMD3(1.3, 2, 3)), "Y projection")
        check(close(d.projected(raw, from: SIMD3(1, 2, 3), constraint: .z), SIMD3(1, 2, 3.6)), "Z projection")
        var g = DrawingDocument()
        let g0 = try g.addVertex(.zero)
        let g1 = try g.addManualLine(from: g0, direction: .plusX, lengthCM: 20)
        let firstLine = g.segments[0].id
        let g2 = try g.addManualLine(from: g1, direction: .plusY, lengthCM: 20)
        let secondLine = g.segments[1]
        let snapshot = g
        try g.resize(firstLine, lengthCM: 10)
        check(close(try g.vertex(g0).position, .zero), "resize fixes start")
        check(close(try g.vertex(g1).position, SIMD3(0.1, 0, 0)), "resize moves end")
        check(secondLine.start == g1 && g.vertices.count == 3, "shared topology")
        check(abs(try g.length(secondLine) - sqrt(0.05)) < 0.00001, "connected edge updates")
        check(close(try g.vertex(g2).position, SIMD3(0.2, 0.2, 0)), "other endpoint fixed")
        try g.shorten(firstLine, byCM: 5)
        check(abs(try g.length(g.segments[0]) - 0.05) < 0.00001, "shorten by 5 cm")
        let stableEncoder = JSONEncoder()
        stableEncoder.outputFormatting = .sortedKeys
        let beforeInvalid = try stableEncoder.encode(g)
        reject("reject zero") { try g.resize(firstLine, lengthCM: 0) }
        reject("reject NaN") { try g.resize(firstLine, lengthCM: .nan) }
        reject("reject excess shortening") { try g.shorten(firstLine, byCM: 99) }
        reject("reject zero-projection correction") { try g.correct(firstLine, constraint: .z) }
        check(try stableEncoder.encode(g) == beforeInvalid, "invalid edits are atomic")
        g = snapshot
        check(close(try g.vertex(g1).position, SIMD3(0.2, 0, 0)), "value snapshot restores shared graph")
        let decoded = try JSONDecoder().decode(DrawingDocument.self, from: JSONEncoder().encode(d))
        check(decoded.vertices.count == d.vertices.count && decoded.segments.count == d.segments.count,
              "document export roundtrip")
        check(decoded.axes.x == d.axes.x && decoded.axes.origin == d.axes.origin, "axes export roundtrip")
        var c = DrawingDocument()
        let c0 = try c.addVertex(.zero)
        let c1 = try c.addMeasuredLine(from: c0, to: SIMD3(0.3, 0.4, 0.5), constraint: .free, sample: nil)
        try c.correct(c.segments[0].id, constraint: .horizontal)
        check(close(try c.vertex(c1).position, SIMD3(0.3, 0.4, 0)), "existing-line horizontal correction")
        try c.resize(c.segments[0].id, lengthCM: 100)
        check(close(try c.vertex(c1).position, SIMD3(0.6, 0.8, 0)), "correction then exact length")
        // A -> B -> C collinear: extending AB onto C must not collapse BC.
        var shared = DrawingDocument()
        let s0 = try shared.addVertex(.zero)
        let s1 = try shared.addManualLine(from: s0, direction: .plusX, lengthCM: 20)
        try shared.addManualLine(from: s1, direction: .plusX, lengthCM: 20)
        reject("reject collapse of connected line") { try shared.resize(shared.segments[0].id, lengthCM: 40) }
        check(close(try shared.vertex(s1).position, SIMD3(0.2, 0, 0)), "collapse rejection keeps vertex")
    } catch {
        failures.append("Unexpected: \(error.localizedDescription)")
    }
    return (count, failures)
}

let result = runGeometryChecks()
print("Geometry checks: \(result.0 - result.1.count)/\(result.0) passed")
for failure in result.1 { print("FAIL: \(failure)") }
exit(result.1.isEmpty ? 0 : 1)
