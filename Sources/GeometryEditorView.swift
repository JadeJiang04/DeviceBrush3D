import SwiftUI

@MainActor
struct GeometryEditorView: View {
    @ObservedObject var model: MeasurementModel
    @State private var panel = 0
    @State private var startID: UUID?
    @State private var originID: UUID?
    @State private var xID: UUID?
    @State private var lineID: UUID?
    @State private var direction: AxisDirection = .plusX
    @State private var correction: LineConstraint = .horizontal
    @State private var lengthText = "20"
    @State private var resizeText = "20"
    @State private var shortenText = "5"
    @State private var mergeFrom: UUID?
    @State private var mergeTo: UUID?
    @State private var faceA: UUID?
    @State private var faceB: UUID?
    @State private var faceC: UUID?
    @FocusState private var input: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("撤销") { input = nil; model.undo() }.disabled(!model.canUndo)
                Spacer()
                Text("顶点与线段").font(.headline)
                Spacer()
                Button("完成") { input = nil; model.editorPresented = false }
            }.padding(.horizontal).padding(.top, 8)
            VStack(spacing: 0) {
                Picker("编辑内容", selection: $panel) {
                    Text("从顶点加线").tag(0)
                    Text("改长度 / 矫正").tag(1)
                    Text("原点 / XY 轴").tag(2)
                    Text("合并 / 面 / 色").tag(3)
                }.pickerStyle(.segmented).padding()
                if let message = model.editMessage {
                    Text(message).font(.callout).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal).padding(.bottom, 8)
                }
                Form {
                    if panel == 0 { addSection }
                    if panel == 1 { lineSection }
                    if panel == 2 { axesSection }
                    if panel == 3 { artSection }
                }.id(panel).scrollContentBackground(.hidden).scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("顶点与线段")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("撤销") { input = nil; model.undo() }.disabled(!model.canUndo)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { input = nil; model.editorPresented = false }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("收起键盘") { input = nil }
                }
            }
        }
        .onAppear { reconcileSelections() }
        .onChange(of: model.vertices.map(\.id)) { _ in reconcileSelections() }
        .onChange(of: model.segments.map(\.id)) { _ in reconcileSelections() }
        .onChange(of: lineID) { _ in loadLength() }
        .onChange(of: panel) { _ in input = nil; model.editMessage = nil }
    }

    private var addSection: some View {
        Group {
            if model.vertices.isEmpty {
                Section {
                    Text("先在相机界面点击“仅记录顶点”或“记录起点”。这个实际位置会成为 V1 和默认原点。")
                }
            } else {
                Section("选择起点与方向") {
                    vertexPicker("起始顶点", selection: $startID)
                    Picker("方向", selection: $direction) {
                        ForEach(AxisDirection.allCases) { Text($0.rawValue).tag($0) }
                    }
                    numberField("长度（厘米）", text: $lengthText, key: "add")
                    Button("确认添加线段") {
                        input = nil
                        if let start = startID, let value = number(lengthText) {
                            model.controller?.addManualLine(from: start, direction: direction, lengthCM: value)
                        }
                    }.disabled(startID == nil)
                }
                Section {
                    Button("从此顶点继续相机取点") {
                        input = nil
                        if let id = startID { model.controller?.continueFromVertex(id) }
                    }.disabled(startID == nil || model.hasStart)
                    Text("手动添加会直接生成指定长度的新线段。+Z 向上，−Z 向下；X/Y 方向可在“原点 / XY 轴”中校正。")
                    if let point = model.vertices.first(where: { $0.id == startID }) {
                        Text(coordinates(point)).font(.caption.monospaced())
                    }
                    Text(model.axesDescription).font(.caption)
                }
            }
        }
    }

    private var artSection: some View {
        Group {
            Section("颜色与笔触") {
                Picker("颜色", selection: $model.ink) {
                    ForEach(InkColor.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("笔触", selection: $model.inkStyle) {
                    ForEach(InkStyle.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("已有线段", selection: $lineID) {
                    ForEach(model.segments) { Text($0.title).tag(Optional($0.id)) }
                }
                Button("应用到所选线段") { if let id = lineID { model.controller?.paintLine(id) } }
                    .disabled(lineID == nil)
            }
            Section("合并顶点") {
                vertexPicker("移动这个点", selection: $mergeFrom)
                vertexPicker("合并到这个点", selection: $mergeTo)
                Text("保留目标点的位置，所有相连线段改接目标点；重合线与零长度线会移除。若使已有面退化则取消。")
                Button("确认合并") {
                    if let a = mergeFrom, let b = mergeTo { model.controller?.mergePoints(a, into: b) }
                }.disabled(model.hasStart || mergeFrom == nil || mergeTo == nil)
            }
            Section("三点确定平面并填色") {
                vertexPicker("顶点 A", selection: $faceA)
                vertexPicker("顶点 B", selection: $faceB)
                vertexPicker("顶点 C", selection: $faceC)
                Text("填充三点围成的三角面，颜色采用上方选择。多个三角面可拼成墙面或其他形状。")
                Button("确认生成彩色面") {
                    if let a = faceA, let b = faceB, let c = faceC { model.controller?.createFace([a, b, c]) }
                }.disabled(model.hasStart || faceA == nil || faceB == nil || faceC == nil)
                ForEach(Array(model.faces.enumerated()), id: \.element.id) { index, face in
                    HStack {
                        Text("面 \(index + 1) · \(face.color.rawValue)")
                        Spacer()
                        Button("改色") { model.controller?.paintFace(face.id) }
                        Button("删除") { model.controller?.deleteFace(face.id) }
                    }.buttonStyle(.borderless)
                }
            }
        }
    }

    private var lineSection: some View {
        Group {
            if model.segments.isEmpty {
                Section { Text("先记录一条线，或从顶点按长度添加一条线。") }
            } else {
                Section("选择要修改的线段") {
                    Picker("线段", selection: $lineID) {
                        ForEach(model.segments) { Text($0.title).tag(Optional($0.id)) }
                    }
                    if let line = model.segments.first(where: { $0.id == lineID }) {
                        Text("固定 \(line.startName)，移动 \(line.endName)。当前：\(MeasurementModel.length(line.lengthCM))")
                        if line.isPolyline {
                            Text("连续笔迹按整条折线编辑，中间点不显示。长度为沿线总长；目标长度按比例缩放，减少长度则从末端裁短。")
                                .font(.caption)
                        }
                        Text("上次操作：\(line.operation)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("修改长度") {
                    numberField("目标长度（厘米）", text: $resizeText, key: "resize")
                    Button("确认目标长度") {
                        input = nil
                        if let id = lineID, let value = number(resizeText) {
                            model.controller?.resizeLine(id, lengthCM: value)
                        }
                    }
                    numberField("减少（厘米）", text: $shortenText, key: "shorten")
                    Button("确认缩短") {
                        input = nil
                        if let id = lineID, let value = number(shortenText) {
                            model.controller?.shortenLine(id, byCM: value)
                            loadLength()
                        }
                    }
                }
                Section("线段方向矫正") {
                    Picker("方向", selection: $correction) {
                        ForEach(LineConstraint.allCases.filter { $0 != .free }) { Text($0.rawValue).tag($0) }
                    }
                    Button("确认方向矫正") {
                        input = nil
                        if let id = lineID {
                            model.controller?.correctLine(id, constraint: correction)
                            loadLength()
                        }
                    }
                    Text("水平 XY：终点与起点同高；沿轴：将终点投影到经过起点的轴线上。投影会改变长度，需要时再输入目标长度。")
                }
                Section {
                    Text("共用这个终点的其他线段会一起改变，保持连接。这些是几何编辑，不代表重新测量；可以撤销。")
                }
            }
        }
    }

    private var axesSection: some View {
        Group {
            Section("Z 竖直向上，XY 为水平面") {
                Text("竖直方向采用 ARKit 的重力姿态融合。陀螺仪配合加速度计与相机跟踪，不需要把 iPad 放平。")
                Text(model.axesDescription)
                if model.vertices.count >= 2 {
                    vertexPicker("原点", selection: $originID)
                    vertexPicker("+X 指向", selection: $xID)
                    Button("确认原点与 XY 轴") {
                        input = nil
                        if let origin = originID, let x = xID {
                            model.controller?.calibrateAxes(origin: origin, toward: x)
                        }
                    }.disabled(model.hasStart)
                    Text("取两点连线的水平方向作为 +X；+Y 按右手坐标系确定。建议选水平间距较大的两点。校正不会移动图形。")
                    if model.hasStart { Text("请先完成或撤销当前线段，再校正坐标。") }
                } else {
                    Text("至少记录两个顶点后，可确定原点和 +X 方向。")
                }
            }
            Section("顶点坐标 · 厘米") {
                ForEach(model.vertices) { point in
                    Text(coordinates(point)).font(.callout.monospaced())
                }
            }
        }
    }

    private func vertexPicker(_ title: String, selection: Binding<UUID?>) -> some View {
        Picker(title, selection: selection) {
            ForEach(model.vertices) { Text($0.name).tag(Optional($0.id)) }
        }
    }
    private func numberField(_ title: String, text: Binding<String>, key: String) -> some View {
        HStack {
            Text(title)
            TextField("厘米", text: text).multilineTextAlignment(.trailing)
                .keyboardType(.decimalPad).focused($input, equals: key)
                .frame(maxWidth: 200)
        }
    }
    private func number(_ text: String) -> Float? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard let value = Float(clean), value.isFinite else {
            model.editMessage = "请输入有效的厘米数值。"
            return nil
        }
        return value
    }
    private func coordinates(_ vertex: VertexSummary) -> String {
        let p = vertex.coordinatesCM
        return String(format: "%@  X %.1f   Y %.1f   Z %.1f", vertex.name, p.x, p.y, p.z)
    }
    private func reconcileSelections() {
        let ids = model.vertices.map(\.id)
        if !ids.contains(where: { $0 == mergeFrom }) { mergeFrom = ids.last }
        if !ids.contains(where: { $0 == mergeTo }) { mergeTo = ids.first }
        if !ids.contains(where: { $0 == faceA }) { faceA = ids.first }
        if !ids.contains(where: { $0 == faceB }) { faceB = ids.dropFirst().first }
        if !ids.contains(where: { $0 == faceC }) { faceC = ids.dropFirst(2).first }
        if !ids.contains(where: { $0 == startID }) { startID = ids.last }
        if !ids.contains(where: { $0 == originID }) { originID = ids.first }
        if !ids.contains(where: { $0 == xID }) { xID = ids.last }
        if !model.segments.contains(where: { $0.id == lineID }) {
            lineID = model.segments.last?.id
            loadLength()
        }
    }
    private func loadLength() {
        if let line = model.segments.first(where: { $0.id == lineID }) {
            resizeText = String(format: "%.2f", line.lengthCM)
        }
    }
}
