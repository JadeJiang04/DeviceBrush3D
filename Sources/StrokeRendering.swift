import SceneKit
import UIKit
import simd
import SwiftUI

enum RibbonRenderer {
    static func material(color: InkColor, style: InkStyle) -> SCNMaterial {
        let c = color.rgb
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.isDoubleSided = true
        if style == .pencil { m.diffuse.contents = grain }
        else { m.diffuse.contents = UIColor.white }
        m.diffuse.wrapT = .repeat
        m.diffuse.wrapS = .clamp
        m.multiply.contents = UIColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
        m.writesToDepthBuffer = style != .pencil
        m.blendMode = .alpha
        return m
    }
    // Procedural paper grain; the supplied BMP is a visual reference, not a repeated photograph.
    private static let grain: UIImage = {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32), format: format).image { ctx in
            var seed: UInt32 = 2157
            for y in 0..<32 {
                for x in 0..<32 {
                    seed = seed &* 1664525 &+ 1013904223
                    let noise = CGFloat(seed % 1000) / 1000
                    let edge = min(1, CGFloat(min(x, 31 - x)) / 3)
                    let alpha = edge * (0.18 + 0.78 * noise)
                    ctx.cgContext.setFillColor(UIColor(white: 0.55 + noise * 0.45, alpha: alpha).cgColor)
                    ctx.cgContext.fill(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
    }()

    static func geometry(points: [SIMD3<Float>], camera: SIMD3<Float>, cameraRight: SIMD3<Float>,
                         width: Float, material: SCNMaterial) -> SCNGeometry? {
        guard points.count >= 2 else { return nil }
        var vertices: [SCNVector3] = []
        var uv: [CGPoint] = []
        var indices: [Int32] = []
        var length: Float = 0
        var previousSide = cameraRight
        for i in points.indices {
            let before = points[max(0, i - 1)]
            let after = points[min(points.count - 1, i + 1)]
            var tangent = after - before
            if i > 0 && i < points.count - 1 {
                let incoming = points[i] - before
                let outgoing = after - points[i]
                if simd_length(incoming) > 0.000001 && simd_length(outgoing) > 0.000001 {
                    tangent = simd_normalize(incoming) + simd_normalize(outgoing)
                }
            }
            var side = simd_cross(tangent, camera - points[i])
            if simd_length(side) < 0.000001 { side = previousSide }
            side = simd_normalize(side)
            if simd_dot(side, previousSide) < 0 { side = -side }
            previousSide = side
            if i > 0 { length += simd_distance(points[i], points[i - 1]) }
            var miter: Float = 1
            if i > 0 && i < points.count - 1 {
                let outerSide = simd_cross(after - points[i], camera - points[i])
                if simd_length(outerSide) > 0.000001 {
                    miter = min(2, 1 / max(0.5, abs(simd_dot(side, simd_normalize(outerSide)))))
                }
            }
            let half = side * width * 0.5 * miter
            vertices.append(SCNVector3(points[i] - half)); vertices.append(SCNVector3(points[i] + half))
            uv.append(CGPoint(x: 0, y: CGFloat(length / 0.02)))
            uv.append(CGPoint(x: 1, y: CGFloat(length / 0.02)))
            if i > 0 {
                let n = Int32(i * 2)
                indices += [n - 2, n - 1, n, n - 1, n + 1, n]
            }
        }
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(textureCoordinates: uv)],
                                   elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        geometry.firstMaterial = material
        return geometry
    }
}

// UIKit owns the press lifecycle so a finger sliding outside, cancellation, or a short tap
// cannot leave a recording running. A short tap creates no point.
struct HoldDrawingButton: UIViewRepresentable {
    var enabled: Bool
    var drawing: Bool
    var began: () -> Void
    var ended: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.backgroundColor = .systemOrange
        button.tintColor = .white
        button.layer.cornerRadius = 16
        let press = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.press(_:)))
        press.minimumPressDuration = 0.18
        press.allowableMovement = 10000
        button.addGestureRecognizer(press)
        return button
    }
    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.parent = self
        button.isUserInteractionEnabled = enabled || drawing
        button.alpha = enabled || drawing ? 1 : 0.4
        button.setTitle(drawing ? "正在绘制 · 松手结束" : "按住绘制 · 移动 iPad", for: .normal)
        button.titleLabel?.font = .boldSystemFont(ofSize: 20)
    }
    static func dismantleUIView(_ view: UIButton, coordinator: Coordinator) { coordinator.parent.ended() }
    final class Coordinator: NSObject {
        var parent: HoldDrawingButton
        init(_ parent: HoldDrawingButton) { self.parent = parent }
        @objc func press(_ gesture: UILongPressGestureRecognizer) {
            switch gesture.state {
            case .began: parent.began()
            case .ended, .cancelled, .failed: parent.ended()
            default: break
            }
        }
    }
}
