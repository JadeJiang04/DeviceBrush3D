import SwiftUI
import simd
import UIKit
import Darwin

enum HardwareProfile {
    static var identifier: String {
        var info = utsname(); uname(&info)
        return withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }
    }
    static var supported: Bool { identifier == "iPad14,3" }
    static var description: String {
        supported ? "iPad Pro 11 英寸（第四代） · iPad14,3" : "\(identifier) · 暂无镜头尺寸预设，请手动校准"
    }
}

enum DeviceCorner: String, Codable, CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight
    var id: String { rawValue }
    var isTop: Bool { self == .topLeft || self == .topRight }
    var isLeft: Bool { self == .topLeft || self == .bottomLeft }
    var name: String { "竖屏" + (isLeft ? "左" : "右") + (isTop ? "上" : "下") + "角" }

    static func upperLeft(in orientation: UIInterfaceOrientation) -> DeviceCorner? {
        switch orientation {
        case .portrait: return .topLeft
        case .portraitUpsideDown: return .bottomRight
        case .landscapeRight: return .topRight // Front camera at left.
        case .landscapeLeft: return .bottomLeft
        default: return nil
        }
    }
}

enum CaptureMode: String, CaseIterable, Identifiable, Codable {
    case device = "设备画笔"
    case surface = "准星测距"
    var id: String { rawValue }
}

struct TipOffset: Codable, Equatable {
    var enabled = false
    // ARKit camera coordinates, independent of interface rotation:
    // UIDeviceOrientation.landscapeLeft: X right, Y up, Z toward the viewer.
    var xCM: Double = 0
    var yCM: Double = 0
    var zCM: Double = 0
    var corner: DeviceCorner? = nil

    static func iPadCorner(_ corner: DeviceCorner) -> TipOffset {
        // Apple dimensional drawing, iPad Pro 11-inch (4th generation), sheets 1-2:
        // W=178.52, H=247.64, wide-camera axis 13.12 from REAR left, 25.14 from top (mm).
        // Front view mirrors the rear: camera is 178.52-13.12=165.40 mm from FRONT left.
        // Camera X points down in portrait; camera Y points right; Z points toward screen.
        // The rounded-corner inset (4 mm) and optical-center Z (3 mm) are estimates,
        // not values specified by Apple's drawing. User calibration may refine them.
        let inset = 4.0
        let frontX = corner.isLeft ? inset : 178.52 - inset
        let frontY = corner.isTop ? inset : 247.64 - inset
        return TipOffset(enabled: true, xCM: (frontY - 25.14) / 10,
                         yCM: (frontX - 165.40) / 10, zCM: 0.30, corner: corner)
    }

    var meters: SIMD3<Float> {
        guard enabled else { return .zero }
        return SIMD3(Float(xCM), Float(yCM), Float(zCM)) / 100
    }
}

struct SegmentSummary: Identifiable {
    let id: UUID
    let number: Int
    let lengthCM: Float
    let startName: String
    let endName: String
    let operation: String
    var isPolyline = false
    var title: String { "\(number) · \(startName) → \(endName) · \(String(format: "%.1f cm", lengthCM))" }
}

struct VertexSummary: Identifiable {
    let id: UUID
    let name: String
    let coordinatesCM: SIMD3<Float>
}

struct ScreenLabel: Identifiable {
    let id: UUID
    let text: String
    let point: CGPoint
    let isStart: Bool
}

struct ExportFile: Identifiable {
    let id = UUID()
    let url: URL
}

@MainActor
final class MeasurementModel: ObservableObject {
    @Published var mode: CaptureMode = .device
    @Published var tip = TipOffset()
    @Published var trackingText = "正在启动相机"
    @Published var hint = "缓慢移动 iPad，让后置相机看到有纹理的物体。"
    @Published var canCapture = false
    @Published var hasStart = false
    @Published var isTracking = false
    @Published var isInterrupted = false
    @Published var cameraDenied = false
    @Published var lidarAvailable = false
    @Published var liveLengthCM: Float?
    @Published var relativeCM: SIMD3<Float>?
    @Published var labels: [ScreenLabel] = []
    @Published var segments: [SegmentSummary] = []
    @Published var notice: String?
    @Published var exportFile: ExportFile?
    @Published var settingsPresented = false
    @Published var editorPresented = false
    @Published var constraint: LineConstraint = .free
    @Published var vertices: [VertexSummary] = []
    @Published var axesDescription = "XY 水平，Z 向上；X 暂用初始定位方向"
    @Published var canUndo = false
    @Published var editMessage: String?
    @Published var ink: InkColor = .green
    @Published var inkStyle: InkStyle = .pencil
    @Published var faces: [DrawingFace] = []
    @Published var outwardCM = 0.5
    @Published var forwardCM = 8.0
    @Published var freehand = true
    @Published var isDrawing = false
    @Published var brushMM = 4.0
    @Published var pathCount = 0
    @Published var simplifyMM = 3.0

    weak var controller: ARMeasurementController?

    init() {
        if UserDefaults.standard.object(forKey: "tip.outwardCM") != nil {
            outwardCM = UserDefaults.standard.double(forKey: "tip.outwardCM")
            forwardCM = UserDefaults.standard.double(forKey: "tip.forwardCM")
        }
        if let data = UserDefaults.standard.data(forKey: "tipOffset.v1"),
           let value = try? JSONDecoder().decode(TipOffset.self, from: data),
           [value.xCM, value.yCM, value.zCM].allSatisfy({ $0.isFinite && abs($0) <= 100 }) {
            tip = value
        }
    }

    func saveTip() {
        UserDefaults.standard.set(outwardCM, forKey: "tip.outwardCM")
        UserDefaults.standard.set(forwardCM, forKey: "tip.forwardCM")
        if let data = try? JSONEncoder().encode(tip) {
            UserDefaults.standard.set(data, forKey: "tipOffset.v1")
        }
    }

    func selectCurrentCorner() {
        guard !hasStart else { return }
        guard HardwareProfile.supported else {
            notice = "\(HardwareProfile.description)。已保留当前偏移，可在设置中手动输入。"
            return
        }
        guard let corner = controller?.currentUpperLeftCorner else {
            notice = "暂时无法确定屏幕方向，请关闭设置后再试。"
            return
        }
        tip = .iPadCorner(corner)
        tip.xCM += (corner.isTop ? -1 : 1) * (0.4 + outwardCM)
        tip.yCM += (corner.isLeft ? -1 : 1) * (0.4 + outwardCM)
        tip.zCM = -forwardCM
        saveTip()
    }

    func selectCameraCenter() {
        guard !hasStart else { return }
        tip.enabled = false
        saveTip()
    }

    func capture() { controller?.capture() }
    func undo() { controller?.undo() }
    func restart() { controller?.restart() }
    func export() { controller?.exportMeasurements() }
    func recordVertex() { controller?.capture(vertexOnly: true) }

    func openEditor() {
        editMessage = nil
        editorPresented = true
    }

    var tipDescription: String {
        if mode == .surface { return "画面中央准星指向的表面" }
        if !tip.enabled { return "后置相机光学中心（无偏移）" }
        if let corner = tip.corner { return "当前左上角 · \(corner.name) · 前伸 \(String(format: "%.1f", forwardCM)) cm" }
        return "相机中心 + 自定义笔尖偏移"
    }

    static func length(_ centimeters: Float) -> String {
        String(format: "%.1f cm", centimeters)
    }
}
