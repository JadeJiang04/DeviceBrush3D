import SwiftUI
import UIKit

@MainActor
struct ContentView: View {
    @StateObject private var model = MeasurementModel()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var confirmReset = false
    @State private var showCoordinates = false
    @State private var editorOffset = CGSize.zero
    @State private var editorDragOrigin = CGSize.zero
    @State private var controlsCollapsed = true
    @State private var editorCollapsed = false

    var body: some View {
        ZStack {
            ARCameraView(model: model).ignoresSafeArea()

            // Coordinates are local to the full ARView, so this overlay must
            // use the same full-screen geometry, including safe-area insets.
            GeometryReader { geometry in
                ForEach(model.labels) { label in
                    if label.text.contains("笔尖") {
                        Image(systemName: "plus").font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.orange).shadow(color: .black, radius: 2)
                            .position(label.point)
                    }
                    Text(label.text)
                        .font(.caption.bold())
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(label.isStart ? Color.orange : Color.blue, in: Capsule())
                        .position(x: label.point.x, y: label.point.y - 22)
                }
                if model.mode == .surface {
                    Image(systemName: "plus.viewfinder")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(model.canCapture ? Color.mint : Color.white)
                        .shadow(color: .black, radius: 3)
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                }
            }
            .ignoresSafeArea().allowsHitTesting(false)

            VStack(spacing: 8) {
                HStack {
                    Circle().fill(model.isTracking ? Color.mint : Color.orange).frame(width: 7, height: 7)
                    Text(model.trackingText).font(.caption)
                    Spacer()
                    Button { model.settingsPresented = true } label: { Image(systemName: "slider.horizontal.3") }
                        .disabled(model.hasStart)
                    Button { controlsCollapsed.toggle() } label: {
                        Image(systemName: controlsCollapsed ? "arrow.up.left.and.arrow.down.right" : "minus")
                            .frame(width: 32, height: 32)
                    }.disabled(model.isDrawing).accessibilityLabel(controlsCollapsed ? "展开工具" : "收起工具")
                }
                if model.hasStart && !model.isDrawing {
                    Text(model.liveLengthCM.map(MeasurementModel.length) ?? "等待恢复跟踪")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .padding(.horizontal, 20).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                if controlsCollapsed {
                    if model.freehand {
                        HoldDrawingButton(enabled: model.canCapture && (!model.hasStart || model.isDrawing), drawing: model.isDrawing,
                                          began: { model.controller?.beginStroke() }, ended: { model.controller?.endStroke() })
                            .frame(height: 48)
                    } else {
                        Button(model.hasStart ? "记录终点" : "记录起点") { model.capture() }
                            .buttonStyle(.borderedProminent).disabled(!model.canCapture)
                    }
                    HStack {
                        Button("撤销") { model.undo() }.disabled(!model.canUndo || model.isDrawing)
                        Spacer()
                        Button("编辑") { model.openEditor() }.disabled(model.isDrawing)
                        Text("\(model.pathCount) 笔").font(.caption)
                    }
                } else {
                    ScrollView { controls }.frame(maxHeight: 330)
                }
            }
            .padding(12)
            .frame(width: controlsCollapsed ? 270 : 350)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            if model.settingsPresented {
                settings
                    .background(Color(uiColor: .systemBackground))
                    .ignoresSafeArea()
                    .zIndex(2)
            }
            if model.editorPresented {
                GeometryReader { area in
                    let width = min(editorCollapsed ? 230.0 : 430.0, area.size.width - 24)
                    let height = min(editorCollapsed ? 48.0 : 430.0, area.size.height - 24)
                    VStack(spacing: 0) {
                        HStack {
                            Image(systemName: "hand.draw")
                            Text("顶点编辑").font(.caption)
                            Spacer()
                            Button { editorCollapsed.toggle() } label: { Image(systemName: editorCollapsed ? "arrow.up.left.and.arrow.down.right" : "minus") }
                            Button { model.editorPresented = false } label: { Image(systemName: "xmark.circle.fill") }
                        }.padding(12).contentShape(Rectangle())
                            .gesture(DragGesture().onChanged { value in
                                editorOffset = CGSize(width: editorDragOrigin.width + value.translation.width,
                                                      height: editorDragOrigin.height + value.translation.height)
                            }.onEnded { _ in editorDragOrigin = editorOffset })
                        if !editorCollapsed { GeometryEditorView(model: model) }
                    }
                    .frame(width: width, height: height)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.25)))
                    .shadow(radius: 12)
                    .position(x: min(area.size.width - width / 2 - 12, max(width / 2 + 12, area.size.width - width / 2 - 12 + editorOffset.width)),
                              y: min(area.size.height - height / 2 - 12, max(height / 2 + 12, area.size.height - height / 2 - 12 + editorOffset.height)))
                }.zIndex(3)
            }
        }
        .sheet(item: $model.exportFile) { item in
            ShareSheet(url: item.url)
        }
        .alert("提示", isPresented: Binding(
            get: { model.notice != nil },
            set: { if !$0 { model.notice = nil } }
        )) {
            Button("知道了", role: .cancel) { model.notice = nil }
        } message: { Text(model.notice ?? "") }
        .confirmationDialog("重新定位会清除当前线段和原点。请先导出需要保留的数据。",
                            isPresented: $confirmReset, titleVisibility: .visible) {
            Button("清除并重新定位", role: .destructive) { model.restart() }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { model.controller?.resume() }
            else { model.controller?.endStroke(); if phase == .background { model.controller?.pause() } }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(model.isTracking ? Color.mint : Color.orange).frame(width: 8, height: 8)
                Text(model.trackingText).font(.headline)
                Spacer()
                if model.lidarAvailable { Text("LiDAR").font(.caption).foregroundStyle(.secondary) }
                Button { model.settingsPresented = true } label: {
                    Image(systemName: "slider.horizontal.3")
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .disabled(model.hasStart)
                .accessibilityLabel("笔尖设置")
            }
            Text(model.hint).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            if model.cameraDenied {
                Button("打开设置，允许相机") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                }
            }
            if showCoordinates, let p = model.relativeCM {
                Text(String(format: "X %.1f   Y %.1f   Z↑ %.1f cm", p.x, p.y, p.z))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var controls: some View {
        VStack(spacing: 12) {
            Picker("取点方式", selection: $model.mode) {
                ForEach(CaptureMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
            }
            .pickerStyle(.segmented).disabled(model.hasStart)

            Text(model.tipDescription).font(.caption).foregroundStyle(.secondary)
            if model.mode == .device {
                HStack {
                    Button("设为当前左上角") { model.selectCurrentCorner() }
                    Spacer()
                    Button("相机中心") { model.selectCameraCenter() }
                }
                .font(.caption).disabled(model.hasStart)
            }

            if !model.segments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(model.segments) { segment in
                            Text("\(segment.number)  ·  \(MeasurementModel.length(segment.lengthCM))")
                                .font(.caption.monospacedDigit())
                        }
                    }
                }
                .frame(height: 20)
            }

            HStack {
                Menu {
                    Picker("新线段约束", selection: $model.constraint) {
                        ForEach(LineConstraint.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: { Label(model.constraint.rawValue, systemImage: "level") }
                    .disabled(model.hasStart)
                Spacer()
                Button("顶点 / 编辑") { model.openEditor() }.disabled(model.isDrawing)
            }.font(.subheadline)
            HStack {
                Picker("颜色", selection: $model.ink) {
                    ForEach(InkColor.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("笔触", selection: $model.inkStyle) {
                    ForEach(InkStyle.allCases) { Text($0.rawValue).tag($0) }
                }
            }.font(.caption).disabled(model.hasStart)

            Picker("绘制方式", selection: $model.freehand) {
                Text("长按连续画").tag(true)
                Text("两点直线").tag(false)
            }.pickerStyle(.segmented).disabled(model.hasStart)
            if model.freehand {
                HStack {
                    Text("笔宽 \(model.brushMM, specifier: "%.0f") mm").font(.caption)
                    Slider(value: $model.brushMM, in: 1...15, step: 1)
                    Text("\(model.pathCount) 笔").font(.caption)
                }.disabled(model.isDrawing)
                HoldDrawingButton(enabled: model.canCapture && (!model.hasStart || model.isDrawing), drawing: model.isDrawing,
                                  began: { model.controller?.beginStroke() }, ended: { model.controller?.endStroke() })
                    .frame(height: 56)
            } else {
                Button { model.capture() } label: {
                Label(model.hasStart ? "记录终点 · 画直线" : "记录起点",
                      systemImage: model.hasStart ? "checkmark" : "plus")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent).tint(.orange)
            .disabled(!model.canCapture)
            }

            HStack {
                Button { model.undo() } label: { Label("撤销", systemImage: "arrow.uturn.backward") }
                    .disabled(!model.canUndo)
                Spacer()
                Button { model.export() } label: { Label("导出", systemImage: "square.and.arrow.up") }
                    .disabled((model.segments.isEmpty && model.pathCount == 0) || model.isDrawing)
                Spacer()
                Menu {
                    Button("仅记录顶点") { model.recordVertex() }
                        .disabled(!model.canCapture || model.hasStart)
                    Toggle("显示坐标数值", isOn: $showCoordinates)
                    Button("清除并重新定位", role: .destructive) { confirmReset = true }
                } label: { Label("更多", systemImage: "ellipsis.circle") }
            }
            .font(.subheadline)
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private var settings: some View {
        NavigationStack {
            Form {
                Section("设备画笔的参考点") {
                    Stepper("连续笔迹简化阈值 \(model.simplifyMM, specifier: "%.0f") mm", value: $model.simplifyMM, in: 1...10, step: 1)
                    Text("松手后将笔迹简化为折线，只显示起点和终点。阈值限制几何变化，不代表测量精度；设置对新笔迹生效。")
                    Text(HardwareProfile.description)
                    Stepper("向角外延伸 \(model.outwardCM, specifier: "%.1f") cm", value: $model.outwardCM, in: 0...3, step: 0.1)
                    Stepper("向镜头前方 \(model.forwardCM, specifier: "%.1f") cm", value: $model.forwardCM, in: 2...40, step: 1)
                    Text("调整后点下方按钮应用。橙色“笔尖”标记表示虚拟位置；较远的机身角可能需要更大的前伸距离才能进入视野。")
                    Button("将当前左上角设为笔尖") { model.selectCurrentCorner() }
                    Text("空闲时跟随屏幕左上角；绘制一笔或记录起终点期间锁定物理角，避免中途跳点。橙色十字为实际取点，文字在十字上方。")
                    Toggle("启用笔尖偏移", isOn: $model.tip.enabled)
                    if model.tip.enabled {
                        if let corner = model.tip.corner {
                            HStack(spacing: 20) {
                                ZStack(alignment: cornerAlignment(corner)) {
                                    RoundedRectangle(cornerRadius: 12).stroke(.secondary, lineWidth: 2)
                                    Circle().fill(.orange).frame(width: 13, height: 13).padding(3)
                                }.frame(width: 64, height: 88)
                                VStack(alignment: .leading) {
                                    Text(corner.name).font(.headline)
                                    Text("示意：屏幕朝自己，前置相机在上方").font(.caption)
                                }
                            }
                            Text("已采用 iPad Pro 11 英寸第 4 代尺寸估算；圆角接触位置、镜头光学中心和保护壳仍需实物校准。可在下方微调，或关闭偏移切回相机中心。")
                        }
                        offsetField("X（厘米）", value: $model.tip.xCM)
                        offsetField("Y（厘米）", value: $model.tip.yCM)
                        offsetField("Z（厘米）", value: $model.tip.zCM)
                    }
                }
                Section("怎样填写左上角偏移") {
                    Text("先将 iPad 横向放置，前置相机在左侧，屏幕面向自己。以正在使用的后置相机光学中心为零：X 向屏幕右方，Y 向上，Z 向自己。填写该零点到目标机身角的有符号距离。")
                    Text("这套机身坐标不会随界面旋转。ARKit 用每帧姿态旋转偏移向量，因此绕笔尖转动时会补偿相机的移动。预设是估算值，不代表已校准。")
                    Text("如果原来指的是竖屏左上角，请始终测量同一个物理角，不要随屏幕旋转更换笔尖。")
                }
                Section("取点和坐标") {
                    Text("设备画笔：移动设备本身，点两次，保存两个端点。无需等待识别平面。准星测距：把中心准星分别指向两个实际表面位置后点两次。")
                    Text("绘图坐标：XY 为水平面，Z 竖直向上，由 ARKit 重力姿态确定。第一个顶点默认是原点；在“顶点 / 编辑”中选择两点，可重新确定原点和 X/Y 方向。上面的笔尖偏移使用相机自身坐标，与绘图坐标不同。")
                    Text("失去跟踪时暂停取点，重新对准之前看过的场景。ARKit 有尺度和姿态误差，小数位不是精度承诺。")
                }
            }
            .navigationTitle("空间画笔设置")
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button("完成") {
                    let values = [model.tip.xCM, model.tip.yCM, model.tip.zCM]
                    if values.allSatisfy({ $0.isFinite && abs($0) <= 100 }) {
                        model.saveTip()
                        model.settingsPresented = false
                    } else {
                        model.tip = TipOffset()
                        model.settingsPresented = false
                        model.notice = "偏移必须是 -100 到 100 厘米的有限数值，已恢复为无偏移。"
                    }
                }
            } }
        }
    }

    private func offsetField(_ name: String, value: Binding<Double>) -> some View {
        HStack {
            Text(name)
            TextField("0", value: value, format: .number.precision(.fractionLength(0...2)))
                .multilineTextAlignment(.trailing)
                .keyboardType(.numbersAndPunctuation)
        }
    }

    private func cornerAlignment(_ corner: DeviceCorner) -> Alignment {
        switch corner {
        case .topLeft: return .topLeading
        case .topRight: return .topTrailing
        case .bottomLeft: return .bottomLeading
        case .bottomRight: return .bottomTrailing
        }
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
