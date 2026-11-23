# CornerSketch · 角绘

**把 iPad 的一角当成画笔，在真实空间中画线、连接顶点、构建简单立体结构。**

CornerSketch 是一个原生 iPad 空间绘图原型，使用 SwiftUI、ARKit 和 SceneKit。移动设备即可绘制，后置相机观察普通环境辅助定位，无需打印定位图。

> 当前为实验原型。相同绘图源码已在 iPad 的 Swift Playground 实时视图中运行；独立 App 的云端构建、签名安装及全屏显示仍待验证。仓库里的工作流生成 **未签名 IPA**，不能直接安装。

## 能做什么

| 功能 | 使用方式 |
| --- | --- |
| 设备角画笔 | 以当前屏幕左上角的虚拟延伸点取点，橙色十字标记实际投影位置 |
| 连续绘制 | 长按绘制，移动 iPad，松手结束一笔 |
| 笔迹简化 | 松手后简化为三维折线，保留明显拐角，只公开首尾两个顶点 |
| 两点直线 | 分别记录起点和终点，直接连接直线 |
| 颜色与笔触 | 七种颜色、铅笔颗粒或实线，连续笔迹宽度可调 |
| 几何编辑 | 从顶点按方向和长度添加线段，修改长度、缩短、水平或轴向矫正 |
| 顶点与面 | 手动合并两个顶点；三个不共线顶点生成可改色的三角面 |
| 小窗操作 | 工具窗默认位于右下角；工具窗和可拖动的编辑窗均可收起 |
| 数据导出 | 导出 JSON，包含顶点、线段、笔迹、三角面及坐标定义 |

## 开始绘制

1. 允许相机访问，让后置镜头对准有纹理、光线充足的桌面或键盘，缓慢移动到“已定位”。
2. 保持“设备画笔”，检查橙色十字的位置；在设置中调整角外延伸和镜头前伸距离。
3. 按住绘制按钮，移动设备，松手结束；或展开工具窗切换“两点直线”。
4. 点“编辑”选择顶点、改长度或生成彩色面。内部折线转折点不作为可选顶点展示。
5. 展开工具窗，向下滚动到“导出”，保存绘图 JSON。

空闲时笔尖会随屏幕方向选择左上角，正在绘制或记录起终点时锁定物理角，避免中途换角造成跳点。

### 长度和坐标

- 使用 ARKit 的相机位姿，不自行对加速度做二次积分。
- 用户坐标为右手系，**X/Y 水平，Z 向上**；可用两个已有顶点校正原点与 +X 方向。
- 连续笔迹默认简化容差为 **3 mm**，设置可调 1–10 mm，仅对新笔迹生效。这是几何简化容差，不是测量精度。
- 笔迹总长度沿简化折线计算。修改目标长度以起点为中心等比例缩放；减少长度从末端沿线裁切。
- `paths.points` 为当前几何，`paths.rawPoints` 保留原始采样；编辑后不会覆盖原始采样。
- 默认虚拟笔尖向角外延伸 0.5 cm、向镜头前方延伸 8 cm；它不是贴在机身表面的接触式探头。

## 设备与边界

已连接验证的设备为 **iPad Pro 11 英寸第四代，iPad14,3**。目前仅此型号内置机身和镜头尺寸预设，其他型号需手动填写偏移。工程最低部署目标为 iPadOS 16，需要支持 ARKit 的设备；其他设备尚未验证。

- 笔尖偏移基于机身图纸估算，未完成实物精度标定；不保证厘米级或毫米级测量精度。
- 反光、弱纹理、低照度、遮挡和快速运动会影响跟踪。中断或明显跳变会结束当前笔迹。
- 面目前是**手动三点形成的三角面**，尚不支持自动给任意闭合笔迹填面。
- 编辑窗打开期间暂停取点；关闭后继续绘制。
- 重启会开始新 AR 会话。JSON 可保留几何数据，但尚未实现 ARWorldMap 保存和场景恢复。
- 独立 App 使用全屏配置，最终表现需在完成签名安装后验证；已有 Playground 版本仍受其外围界面限制。

## 项目结构

```text
Sources/
  SpatialPenApp.swift          原生 App 入口
  ContentView.swift            相机覆盖层、工具窗与设置
  ARMeasurementController.swift  AR 跟踪、绘制、撤销及导出
  MeasurementModel.swift       UI 状态、机型与笔尖偏移
  DrawingGeometry.swift       几何模型、简化、共享顶点与编辑
  GeometryEditorView.swift     顶点、长度、坐标轴与面编辑
  StrokeRendering.swift       三维铅笔笔触与长按交互
Tests/main.swift              63 项几何与采样检查
scripts/build-ios.sh           本地与 CI 共用的构建脚本
project.yml                   XcodeGen 项目定义
.github/workflows/build-ipad.yml  手动触发的 Mac 构建
```

项目内部暂保留 `SpatialPen` 作为 target、scheme 和数据文件名称，以延续现有原型；仓库展示名称为 CornerSketch。

## 构建

### 使用 GitHub Actions（Windows 也可操作）

1. 进入仓库的 **Actions → Build iPad App → Run workflow**。
2. 工作流在 Mac runner 上运行几何检查，再用 Xcode 构建设备版应用。
3. 成功后下载 `SpatialPen-unsigned` artifact，解压得到 `SpatialPen-unsigned.ipa` 和 `SHA256SUMS.txt`。
4. 使用自己的 Apple 签名身份完成签名，再安装到设备。工作流本身不需要 Apple 账号、证书或设备配对文件。

工作流仅手动启动，最长运行 20 分钟，构建产物保存 3 天。GitHub 对公开与私有仓库的额度不同，运行前以账号当前的 [Actions 计费规则](https://docs.github.com/en/actions/concepts/billing-and-usage)为准。

### 在 Mac 上构建

安装 Xcode 命令行工具及 [XcodeGen](https://github.com/yonaskolb/XcodeGen)，然后执行：

```bash
bash scripts/build-ios.sh
```

输出为 `output/SpatialPen-unsigned.ipa`。也可用 Xcode 打开生成的 `SpatialPen.xcodeproj`，选择自己的开发团队完成签名。项目默认关闭签名；使用 Xcode 签名运行时需将 `CODE_SIGNING_ALLOWED` 改为 `YES` 并配置相应团队。

仅运行几何检查：

```bash
mkdir -p build
xcrun swiftc Sources/DrawingGeometry.swift Tests/main.swift -o build/geometry-checks
./build/geometry-checks
```

这些检查涵盖简化、误差约束、坐标校正、长度编辑、共享端点、非法操作回滚及 JSON 往返。此前 63 项检查已在 iPad 执行通过；它们不替代真实移动距离与笔尖位置的物理测量验证。

## 参考

- [Google Creative Lab · Just a Line iOS](https://github.com/googlecreativelab/justaline-ios)：参考空间线条组织与渲染思路；未将其源码打包进本仓库。
- [Apple · iPad Pro 11 英寸第四代尺寸图](https://developer.apple.com/download/files/accessories/dimensional-drawings/ipad-pro-11-inch-4th-generation.pdf)：用于机身及镜头位置估算。
- [Apple · ARCamera.transform](https://developer.apple.com/documentation/arkit/arcamera/transform)：相机位姿及固定设备坐标系定义。

## 许可证

本项目使用 [MIT License](LICENSE)，允许使用、修改、分发和商用，须保留版权及许可声明。软件按现状提供，不承诺测量精度或特定用途的适用性。

维护者：[JadeJiang04](https://github.com/JadeJiang04)。
