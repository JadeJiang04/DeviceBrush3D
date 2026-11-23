SpatialPen — iPad 空间画笔

原生 SwiftUI + ARKit + SceneKit 应用，使用相机辅助定位，无需定位图。
支持机身左上角虚拟笔尖、连续笔迹简化、两点直线、顶点编辑、彩色三角面。

Actions → Build iPad App → Run workflow。
成功后下载 SpatialPen-unsigned 构建产物，内含 IPA 和 SHA256 校验值。
IPA 尚未签名，不能直接安装；需要先用自己的 Apple 账号签名。
此仓库不需要 Apple 账号、密码、签名证书或设备配对文件。

原生入口为 Sources/SpatialPenApp.swift，脱离 Playground 实时视图运行。
UIRequiresFullScreen 请求 iPad 全屏兼容模式；最终显示和签名安装需要真机验证。
不包含 ARWorldMap 跨启动恢复；绘图数据可导出 JSON。
